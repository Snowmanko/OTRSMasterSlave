# --
# Kernel/System/Ticket/Event/MasterSlave.pm - master slave ticket
# Copyright (C) 2003-2012 OTRS AG, http://otrs.com/
# --
# $Id: MasterSlave.pm,v 1.1.2.1 2012-05-18 14:24:17 te Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Ticket::Event::MasterSlave;

use strict;
use warnings;
use Kernel::System::LinkObject;

use vars qw($VERSION);
$VERSION = qw($Revision: 1.1.2.1 $) [1];

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # get needed objects
    for (
        qw(ConfigObject TicketObject LogObject UserObject CustomerUserObject SendmailObject TimeObject EncodeObject)
        )
    {
        $Self->{$_} = $Param{$_} || die "Got no $_!";
    }

    $Self->{LinkObject} = Kernel::System::LinkObject->new(%Param);

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(TicketID Event Config)) {
        if ( !$Param{$_} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $_!" );
            return;
        }
    }

    # get ticket attributes
    my %Ticket         = $Self->{TicketObject}->TicketGet( TicketID => $Param{TicketID} );
    my $Count          = $Self->{ConfigObject}->Get('MasterTicketFreeTextField');
    my $TicketFreeText = 'TicketFreeText' . $Count;

    # link master/slave tickets
    if ( $Param{Event} eq 'TicketFreeTextUpdate' ) {
        if ( $Ticket{$TicketFreeText} && $Ticket{$TicketFreeText} =~ /^SlaveOf:(.+?)$/ ) {

            # lookup to find ticket id
            my $SourceKey = $Self->{TicketObject}->TicketIDLookup(
                TicketNumber => $1,
                UserID       => $Param{UserID},
            );

            # create link
            $Self->{LinkObject}->LinkAdd(
                SourceObject => 'Ticket',
                SourceKey    => $SourceKey,
                TargetObject => 'Ticket',
                TargetKey    => $Param{TicketID},
                Type         => 'ParentChild',
                State        => 'Valid',
                UserID       => $Param{UserID},
            );

            # reset free text field
            $Self->{TicketObject}->TicketFreeTextSet(
                Counter  => $Count,
                Value    => $Ticket{$TicketFreeText},
                TicketID => $Param{TicketID},
                UserID   => $Param{UserID},
            );
        }
        return 1;
    }

    # check if it's a master/slave ticket
    return 1 if !$Ticket{$TicketFreeText};
    return 1 if $Ticket{$TicketFreeText} !~ /^(master|yes)$/i;

    # find slaves
    my %Links = $Self->{LinkObject}->LinkKeyList(
        Object1   => 'Ticket',
        Key1      => $Param{TicketID},
        Object2   => 'Ticket',
        State     => 'Valid',
        Type      => 'ParentChild',      # (optional)
        Direction => 'Target',           # (optional) default Both (Source|Target|Both)
        UserID    => $Param{UserID},
    );
    my @TicketIDs;
    for my $TicketID ( keys %Links ) {
        next if !$Links{$TicketID};

        # just take ticket with slave attributes for action
        my %Ticket = $Self->{TicketObject}->TicketGet( TicketID => $TicketID );
        next if !$Ticket{$TicketFreeText};
        next if $Ticket{$TicketFreeText} !~ /^SlaveOf:(\d+)$/;

        # remember ticket id
        push @TicketIDs, $TicketID;
    }

    # no slaves
    if ( !@TicketIDs ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "No Slaves of ticket $Ticket{TicketID}!",
        );
        return 1;
    }

    # auto response action
    if ( $Param{Event} eq 'ArticleSend' ) {
        my @Index = $Self->{TicketObject}->ArticleIndex( TicketID => $Param{TicketID} );
        return 1 if !@Index;
        my %Article = $Self->{TicketObject}->ArticleGet( ArticleID => $Index[$#Index] );

        # mark ticket to prevent a loop
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
            HistoryType  => 'Misc',
            Name         => 'MasterTicketAction: ArticleSend',
        );

        # perform action on linked tickets
        for my $TicketID (@TicketIDs) {
            next if !$Self->_LoopCheck(
                TicketID => $TicketID,
                UserID   => $Param{UserID},
                String   => 'MasterTicketAction: ArticleSend',
            );

            my %TicketSlave = $Self->{TicketObject}->TicketGet( TicketID => $TicketID );

            # try to get the customer data of the slave ticket
            my %Customer;
            if ( $TicketSlave{CustomerUserID} ) {
                %Customer = $Self->{CustomerUserObject}->CustomerUserDataGet(
                    User => $TicketSlave{CustomerUserID},
                );
            }

            # if we can't find a valid UserEmail in CustomerData
            # we have to loop over the reversed articles of the slave ticket
            # and send the mail to the first (from behind) UserEmail we can find
            if ( !$Customer{UserEmail} ) {
                my @Index = $Self->{TicketObject}->ArticleIndex( TicketID => $TicketID );
                next if !@Index;

                @Index = reverse @Index;

                for my $ArticleID (@Index) {
                    my %SlaveArticle = $Self->{TicketObject}->ArticleGet(
                        ArticleID => $ArticleID,
                    );
                    if ( $SlaveArticle{SenderType} eq 'customer' ) {
                        $Customer{UserEmail} = $SlaveArticle{From};
                        last;
                    }
                }
            }

            # if we still have no UserEmail, drop an error
            if ( !$Customer{UserEmail} ) {
                $Self->{TicketObject}->HistoryAdd(
                    TicketID     => $TicketID,
                    CreateUserID => $Param{UserID},
                    HistoryType  => 'Misc',
                    Name =>
                        "MasterTicket: no customer email found, send no master message to customer.",
                );
                next;
            }

            # set the new To for ArticleSend
            $Article{To} = $Customer{UserEmail};

            # rebuild subject
            $Self->{ConfigObject}->Set(
                Key   => 'Ticket::SubjectCleanAllNumbers',
                Value => 1,
            );
            my $Subject = $Self->{TicketObject}->TicketSubjectBuild(
                TicketNumber => $TicketSlave{TicketNumber},
                Subject => $Article{Subject} || '',
            );

            # send article again
            $Self->{TicketObject}->ArticleSend(
                %Article,
                Subject        => $Subject,
                Cc             => '',
                Bcc            => '',
                HistoryType    => 'SendAnswer',
                HistoryComment => "Sent answer to '$Article{To}' based on master ticket.",
                TicketID       => $TicketID,
                UserID         => $Param{UserID},
            );
        }
        return 1;
    }

    # article create
    elsif ( $Param{Event} eq 'ArticleCreate' ) {
        my @Index = $Self->{TicketObject}->ArticleIndex( TicketID => $Param{TicketID} );
        return 1 if !@Index;
        my %Article = $Self->{TicketObject}->ArticleGet( ArticleID => $Index[$#Index] );

        # mark ticket to prevent a loop
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
            HistoryType  => 'Misc',
            Name         => "MasterTicketAction: ArticleCreate",
        );

        # do not process email articles (already done in ArticleSend event!)
        if ( $Article{SenderType} eq 'agent' && $Article{ArticleType} eq 'email-external' ) {
            return 1;
        }

        # set the same state, but only for notes
        if ( $Article{ArticleType} !~ /^note-/i ) {
            return 1;
        }

        # perform action on linked tickets
        for my $TicketID (@TicketIDs) {
            next if !$Self->_LoopCheck(
                TicketID => $TicketID,
                UserID   => $Param{UserID},
                String   => 'MasterTicketAction: ArticleCreate',
            );

            # article create
            $Self->{TicketObject}->ArticleCreate(
                %Article,
                HistoryType    => 'AddNote',
                HistoryComment => 'Added article based on master ticket.',
                TicketID       => $TicketID,
                UserID         => $Param{UserID},
            );
        }
        return 1;
    }

    # state action
    elsif ( $Param{Event} eq 'TicketStateUpdate' ) {

        # mark ticket to prevent a loop
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
            HistoryType  => 'Misc',
            Name         => "MasterTicketAction: TicketStateUpdate",
        );

        # perform action on linked tickets
        for my $TicketID (@TicketIDs) {
            next if !$Self->_LoopCheck(
                TicketID => $TicketID,
                UserID   => $Param{UserID},
                String   => 'MasterTicketAction: TicketStateUpdate',
            );

            # set the same state
            $Self->{TicketObject}->TicketStateSet(
                StateID  => $Ticket{StateID},
                TicketID => $TicketID,
                UserID   => $Param{UserID},
            );
        }
        return 1;
    }

    # set pending time
    elsif ( $Param{Event} eq 'TicketPendingTimeUpdate' ) {

        # mark ticket to prevent a loop
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
            HistoryType  => 'Misc',
            Name         => "MasterTicketAction: TicketPendingTimeUpdate",
        );

        # perform action on linked tickets
        for my $TicketID (@TicketIDs) {
            next if !$Self->_LoopCheck(
                TicketID => $TicketID,
                UserID   => $Param{UserID},
                String   => 'MasterTicketAction: TicketPendingTimeUpdate',
            );

            # set the same pending time
            my $TimeStamp = '0000-00-00 00:00:00';
            if ( $Ticket{RealTillTimeNotUsed} ) {
                my ( $Sec, $Min, $Hour, $Day, $Month, $Year )
                    = $Self->{TimeObject}->SystemTime2Date(
                    SystemTime => $Ticket{RealTillTimeNotUsed},
                    );
                $TimeStamp = "$Year-$Month-$Day $Hour:$Min:$Sec";
            }
            $Self->{TicketObject}->TicketPendingTimeSet(
                String   => $TimeStamp,
                TicketID => $TicketID,
                UserID   => $Param{UserID},
            );
        }
        return 1;
    }

    # priority action
    elsif ( $Param{Event} eq 'TicketPriorityUpdate' ) {

        # mark ticket to prevent a loop
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
            HistoryType  => 'Misc',
            Name         => "MasterTicketAction: TicketPriorityUpdate",
        );

        # perform action on linked tickets
        for my $TicketID (@TicketIDs) {
            next if !$Self->_LoopCheck(
                TicketID => $TicketID,
                UserID   => $Param{UserID},
                String   => 'MasterTicketAction: TicketPriorityUpdate',
            );

            # set the same state
            $Self->{TicketObject}->TicketPrioritySet(
                TicketID   => $TicketID,
                PriorityID => $Ticket{PriorityID},
                UserID     => $Param{UserID},
            );
        }
        return 1;
    }

    # owner action
    elsif ( $Param{Event} eq 'TicketOwnerUpdate' ) {

        # mark ticket to prevent a loop
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
            HistoryType  => 'Misc',
            Name         => "MasterTicketAction: TicketOwnerUpdate",
        );

        # perform action on linked tickets
        for my $TicketID (@TicketIDs) {
            next if !$Self->_LoopCheck(
                TicketID => $TicketID,
                UserID   => $Param{UserID},
                String   => 'MasterTicketAction: TicketOwnerUpdate',
            );

            # set the same state
            $Self->{TicketObject}->TicketOwnerSet(
                TicketID           => $TicketID,
                NewUserID          => $Ticket{OwnerID},
                SendNoNotification => 0,
                UserID             => $Param{UserID},
            );
        }
        return 1;
    }

    # responsible action
    elsif ( $Param{Event} eq 'TicketResponsibleUpdate' ) {

        # mark ticket to prevent a loop
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
            HistoryType  => 'Misc',
            Name         => "MasterTicketAction: TicketResponsibleUpdate",
        );

        # perform action on linked tickets
        for my $TicketID (@TicketIDs) {
            next if !$Self->_LoopCheck(
                TicketID => $TicketID,
                UserID   => $Param{UserID},
                String   => 'MasterTicketAction: TicketResponsibleUpdate',
            );

            # set the same state
            $Self->{TicketObject}->TicketResponsibleSet(
                TicketID           => $TicketID,
                NewUserID          => $Ticket{ResponsibleID},
                SendNoNotification => 0,
                UserID             => $Param{UserID},
            );
        }
        return 1;
    }

    # unlock/lock action
    elsif ( $Param{Event} eq 'TicketLockUpdate' ) {

        # mark ticket to prevent a loop
        $Self->{TicketObject}->HistoryAdd(
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
            HistoryType  => 'Misc',
            Name         => "MasterTicketAction: TicketLockUpdate",
        );

        # perform action on linked tickets
        for my $TicketID (@TicketIDs) {
            next if !$Self->_LoopCheck(
                TicketID => $TicketID,
                UserID   => $Param{UserID},
                String   => 'MasterTicketAction: TicketLockUpdate',
            );

            # set the same state
            $Self->{TicketObject}->TicketLockSet(
                Lock               => $Ticket{Lock},
                TicketID           => $TicketID,
                SendNoNotification => 1,
                UserID             => $Param{UserID},
            );
        }
        return 1;
    }
    return 1;
}

sub _LoopCheck {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(TicketID String UserID)) {
        if ( !$Param{$_} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $_!" );
            return;
        }
    }

    my @Lines = $Self->{TicketObject}->HistoryGet(
        TicketID => $Param{TicketID},
        UserID   => $Param{UserID},
    );
    for my $Data ( reverse @Lines ) {
        if ( $Data->{HistoryType} eq 'Misc' && $Data->{Name} eq $Param{String} ) {
            my $TimeCreated = $Self->{TimeObject}->TimeStamp2SystemTime(
                String => $Data->{CreateTime}
            ) + 15;
            my $TimeCurrent = $Self->{TimeObject}->SystemTime();
            if ( $TimeCreated > $TimeCurrent ) {
                $Self->{TicketObject}->HistoryAdd(
                    TicketID     => $Param{TicketID},
                    CreateUserID => $Param{UserID},
                    HistoryType  => 'Misc',
                    Name         => "MasterTicketLoop: stopped",
                );
                return;
            }
        }
    }
    return 1;
}

1;
