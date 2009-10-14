package Finance::Bank::ID::Base;

use warnings;
use strict;
use Data::Dumper;
use DateTime;
use Log::Log4perl;
use Moose;
use WWW::Mechanize;

=head1 NAME

Finance::Bank::ID::Base - Base class for Finance::Bank::ID::BCA etc

=head1 SYNOPSIS

    # Don't use this module directly, use one of its subclasses instead.

=head1 DESCRIPTION

This module provides a base implementation for L<Finance::Bank::ID::BCA> and
L<Finance::Bank::ID::Mandiri>.

=head1 ATTRIBUTES

=cut

has mech        => (is => 'rw');
has username    => (is => 'rw');
has password    => (is => 'rw');
has logged_in   => (is => 'rw');
has accounts    => (is => 'rw');
has logger      => (is => 'rw',
                    default => sub { Log::Log4perl->get_logger() } );
has logger_dump => (is => 'rw',
                    default => sub { Log::Log4perl->get_logger() } );

has site => (is => 'rw');

has _req_counter => (is => 'rw', default => 0);

=head1 METHODS

=cut

sub _fmtdate {
    my ($self, $dt) = @_;
    $dt->strftime("%Y-%m-%d");
}

sub _dmp {
    my ($self, $var) = @_;
    Data::Dumper->new([$var])->Indent(0)->Terse(1)->Dump;
}

# strip non-digit characters
sub _stripD {
    my ($self, $s) = @_;
    $s =~ s/\D+//g;
    $s;
}

=head2 new(%args)

Create a new instance.

=cut

sub BUILD {
    my ($self, $args) = @_;

    # alias
    $self->username($args->{login}) if $args->{login} && !$self->username;
    $self->username($args->{user})  if $args->{user}  && !$self->username;
    $self->password($args->{pin})   if $args->{pin}   && !$self->password;
}

# if check_sub is supplied, then after the request it will be passed the mech
# object and should return an error string. request is assumed to be failed if
# error string is not empty.

sub _req {
    my ($self, $meth, $args, $check_sub) = @_;
    $self->mech(new WWW::Mechanize) unless $self->mech;
    my $mech = $self->mech;
    my $c = $self->_req_counter + 1;
    $self->_req_counter($c);
    $self->logger->debug("mech request #$c: $meth ".$self->_dmp($args)."");
    my $errmsg = "";
    eval { $mech->$meth(@$args) };
    my $evalerr = $@;

    eval {
        $self->logger_dump->trace(
            "<!-- result of mech request #$c (".$self->_dmp($args)."):\n".
            $mech->response->status_line."\n".
            $mech->response->headers->as_string."\n".
            "-->\n".
            $mech->content
            );
    };
    
    if ($evalerr) {
        # mech dies on error, we catch it so we can log it
        $errmsg = "die: $evalerr";
    } elsif (!$mech->success) {
        # actually mech usually dies if unsuccessful (see above), but
        # this is just in case
        $errmsg = "network error: " . $mech->response->status_line;
    } elsif ($check_sub) {
        $errmsg = $check_sub->($mech);
        $errmsg = "check error: $errmsg" if $errmsg;
    }
    if ($errmsg) {
        $errmsg = "mech request #$c failed: $errmsg";
        $self->logger->fatal($errmsg);
        die $errmsg;
    }
}

=head2 login()

Login to netbanking site.

=cut

sub login {
    die "Should be implemented by child";
}

=head2 logout()

Logout from netbanking site.

=cut

sub logout {
    die "Should be implemented by child";
}

=head2 list_accounts()

List accounts.

=cut

sub list_accounts {
    die "Should be implemented by child";
}

=head2 check_balance([$acct])

=cut

sub check_balance {
    die "Should be implemented by child";
}

=head2 get_balance

Synonym for check_balance.

=cut

sub get_balance { check_balance(@_) }

=head2 get_statement(%args)

Get account statement.

=cut

sub get_statement {
    die "Should be implemented by child";
}

=head2 check_statement

Alias for get_statement

=cut

sub check_statement { get_statement(@_) }

=head2 account_statement

Alias for get_statement

=cut

sub account_statement { get_statement(@_) }

=head2 parse_statement($html_or_text, %opts)

Parse HTML/text into statement data.

=cut

sub parse_statement {
    my ($self, $page, %opts) = @_;
    my $status = 500;
    my $error = "";
    my $stmt = {};

    while (1) {
        my $err;
        if ($err = $self->_ps_detect($page, $stmt)) {
            $status = 400; $error = "Can't detect: $err"; last;
        }
        if ($err = $self->_ps_get_metadata($page, $stmt)) {
            $status = 400; $error = "Can't get metadata: $err"; last;
        }
        if ($err = $self->_ps_get_transactions($page, $stmt)) {
            $status = 400; $error = "Can't get transactions: $err"; last;
        }
        
        if (defined($stmt->{_total_debit_in_stmt})) {
            my $na = $stmt->{_total_debit_in_stmt}; 
            my $nb = 0;
            for (@{ $stmt->{transactions} }) { 
                $nb += $_->{amount} < 0 ? -$_->{amount} : 0;
            }
            if ($na != $nb) {
                $status = 400; 
                $error = "Check failed: total debit do not match ($na vs $nb)";
                last;
            }
        }
        if (defined($stmt->{_total_credit_in_stmt})) {
            my $na = $stmt->{_total_credit_in_stmt}; 
            my $nb = 0;
            for (@{ $stmt->{transactions} }) { 
                $nb += $_->{amount} > 0 ? $_->{amount} : 0;
            }
            if ($na != $nb) {
                $status = 400; 
                $error = "Check failed: total credit do not match ($na vs $nb)";
                last;
            }
        }
        if (defined($stmt->{_num_debit_tx_in_stmt})) {
            my $na = $stmt->{_num_debit_tx_in_stmt}; 
            my $nb = 0;
            for (@{ $stmt->{transactions} }) { 
                $nb += $_->{amount} < 0 ? 1 : 0;
            }
            if ($na != $nb) {
                $status = 400; 
                $error = "Check failed: number of debit transactions ".
                    "do not match ($na vs $nb)";
                last;
            }
        }
        if (defined($stmt->{_num_credit_tx_in_stmt})) {
            my $na = $stmt->{_num_credit_tx_in_stmt}; 
            my $nb = 0;
            for (@{ $stmt->{transactions} }) { 
                $nb += $_->{amount} > 0 ? 1 : 0;
            }
            if ($na != $nb) {
                $status = 400;
                $error = "Check failed: number of credit transactions ".
                    "do not match ($na vs $nb)";
                last;
            }
        }

        $status = 200;
        last;
    }

    $self->logger->trace("parse_statement(): Temporary result: ".$self->_dmp($stmt));
    $self->logger->trace("parse_statement(): Status: $status ($error)");

    $stmt = undef unless $status == 200;
    $self->logger->trace("parse_statement(): Result: ".$self->_dmp($stmt));

    wantarray ? ($status, $error, $stmt) : $stmt;
}

=head1 AUTHOR

Steven Haryanto, C<< <stevenharyanto at gmail.com> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009 Steven Haryanto.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

__PACKAGE__->meta->make_immutable;
1;