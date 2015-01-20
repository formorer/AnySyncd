package Anysyncd::Action::Base;

use Moose;
use MooseX::AttributeHelpers;

use Carp qw (croak);
use AnyEvent::Util;
use AnyEvent::DateTime::Cron;
use AnyEvent::Filesys::Notify;
use IPC::ShareLite;
use Storable qw( freeze thaw );

has 'log' => ( is => 'rw' );
has 'config' => ( is => 'rw', isa => 'HashRef', required => 1 );
has '_timer' => ( is => 'rw', predicate => '_has_timer' );
has '_watcher' => ( is => 'rw' );
has '_is_locked' => (
    traits  => ['Bool'],
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
    handles => {
        _lock        => 'set',
        _unlock      => 'unset',
        _is_unlocked => 'not',
    },
);
has _files => ( is => 'rw' );

#
sub BUILD {
    my $self = shift;

    $self->log(
        Log::Log4perl->get_logger(
            $self->config->{handler} . '::' . $self->config->{name}
        )
    );
    my $share = IPC::ShareLite->new(
        -key     => int( rand(4) ),
        -create  => 'yes',
        -destroy => 'yes'
    ) or die $!;

    $self->_files($share);
    $self->_files->store( freeze( [] ) );

    $self->create_watcher();

    if ( $self->config->{'cron'} ) {
        AnyEvent::DateTime::Cron->new()->add(
            $self->config->{'cron'} => sub {
                $self->create_watcher();
                $self->process_files('full')
                    if (!$self->noop
                    and !$self->_timer
                    and $self->_is_unlocked );
            }
        )->start;
    }
}

sub files_clear {
    my $self = shift;
    $self->_files->store( freeze( [] ) );
}

sub create_watcher {
    my $self = shift;
    if ( $self->_watcher and $self->noop() ) {
        $self->_watcher(undef);
        $self->log->info( "Watcher removed for " . $self->config->{name} );
    } elsif ( not $self->_watcher ) {
        $self->_watcher(
            AnyEvent::Filesys::Notify->new(
                dirs         => [ $self->config->{watcher} ],
                filter       => sub { shift !~ /$self->config->{filter}/ },
                parse_events => 1,
                cb           => sub {
                    foreach my $event (@_) {
                        $self->add_files( $event->path );
                    }
                }
            )
        );
        if ( $self->_watcher ) {
            $self->log->info( "Watcher added for " . $self->config->{name} );
        }
    }
}

sub noop {
    my $self = shift;
    return ( $self->config->{'noop_file'}
            and not -e $self->config->{'noop_file'} );
}

sub files {
    my $self = shift;
    if (@_) {
        my @files;
        if ( $self->_files->fetch ) {
            push @files, thaw( $self->_files->fetch );
            push @files, @_;
        } else {
            @files = (@_);
        }
        $self->_files->store( freeze( \@files ) );
    } else {
        return $self->_files->fetch ? thaw( $self->_files->fetch ) : [];
    }
}

sub add_files {
    my $self      = shift;
    my @new_files = (@_);

    $self->create_watcher();
    return unless $self->_watcher;

    $self->files(@new_files);
    $self->log->debug(
        "Added " . join( " ", @new_files ) . " to files queue" );

    if ( !$self->_timer && $self->_is_unlocked ) {
        my $waiting_time = $self->config->{'waiting_time'} || 5;
        my $w = AnyEvent->timer(
            after => $waiting_time,
            cb    => sub { $self->process_files }
        );
        $self->_timer($w);
    }
}

1;

=head1 LICENSE

This is released under the MIT License. See the B<COPYRIGHT> file.

=head1 AUTHOR

Alexander Wirt <alexander.wirt@credativ.de>

=cut

# vim: syntax=perl sw=4 ts=4 et shiftround
