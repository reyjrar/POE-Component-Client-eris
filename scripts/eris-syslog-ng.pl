#!/usr/bin/env perl
#
# This is the POE Master Server.
#  1) Take all the syslog input
#  2) Listen for parsers
#  3) Filter streams to parsers

use strict;
use warnings;

use Socket;

# POE System
use POE qw(
	Wheel::ReadWrite
	Component::Server::TCP
);


my %cooked = (
	program => qr/\s+\d+:\d+:\d+\s+\S+\s+([^:\s]+)(:|\s)/,
);

#--------------------------------------------------------------------------#
# POE Session Initialization


# Dispatcher Master Session
POE::Session->create(
	inline_states => {
		_start					=> \&dispatcher_start,
		_stop					=> sub { print "SESSION ", $_[SESSION]->ID, " stopped.\n"; },
		register_client			=> \&register_client,
		subscribe_client		=> \&subscribe_client,
		unsubscribe_client		=> \&unsubscribe_client,
		fullfeed_client			=> \&fullfeed_client,
		dispatch_message		=> \&dispatch_message,
		broadcast				=> \&broadcast,
		hangup_client			=> \&hangup_client,
		server_shutdown			=> \&server_shutdown,
		match_client			=> \&match_client,
		nomatch_client			=> \&nomatch_client,
		debug_client			=> \&debug_client,
		nobug_client			=> \&nobug_client,
		debug_message			=> \&debug_message,
	},
);

# TCP Session Master
POE::Component::Server::TCP->new(
		Alias		=> 'server',
		Address		=> '127.0.0.1',
		Port		=> 9514,

		ClientConnected		=> \&client_connect,
		ClientInput			=> \&client_input,

		ClientDisconnected	=> \&client_term,
		ClientError			=> \&client_term,

		InlineStates		=> {
			client_print		=> \&client_print,
		},
);

# Syslog-ng Stream Master
POE::Session->create(
		inline_states => {
			_start		=> \&stream_start,
			_stop		=> sub { print "SESSION ", $_[SESSION]->ID, " stopped.\n"; },

			stream_line		=> \&stream_line,
			stream_error	=> \&stream_error,
		},
);

#--------------------------------------------------------------------------#

#--------------------------------------------------------------------------#
# POE Main Loop
POE::Kernel->run();
exit 0;
#--------------------------------------------------------------------------#


#--------------------------------------------------------------------------#
# POE Event Functions
#--------------------------------------------------------------------------#

#--------------------------------------------------------------------------#
sub debug {
	my $msg = shift;
	chomp($msg);
	$poe_kernel->post( 'dispatcher' => 'debug_message' => $msg );
	print "[debug] $msg\n";
}
#--------------------------------------------------------------------------#
sub dispatcher_start {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	$kernel->alias_set( 'dispatcher' );

	$heap->{subscribers} = { };
	$heap->{full} = { };
	$heap->{debug} = { };
	$heap->{match} = { };
}

#--------------------------------------------------------------------------#
sub register_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	$heap->{clients}{$sid} = 1;
}

#--------------------------------------------------------------------------#
sub debug_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	if( exists $heap->{full}{$sid} ) {  return;  }

	$heap->{debug}{$sid} = 1;
	$kernel->post( $sid => 'client_print' => 'Debugging enabled.' );
}

#--------------------------------------------------------------------------#
sub nobug_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	delete $heap->{debug}{$sid}
		if exists $heap->{debug}{$sid};
	$kernel->post( $sid => 'client_print' => 'Debugging disabled.' );
}

#--------------------------------------------------------------------------#
sub fullfeed_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	#
	# Remove from normal subscribers.
	foreach my $prog (keys %{ $heap->{subscribers} }) {
		delete $heap->{subscribers}{$prog}{$sid}
			if exists $heap->{subscribers}{$prog}{$sid};
	}

	#
	# Turn off DEBUG
	if( exists $heap->{debug}{$sid} ) {
		delete $heap->{debug}{$sid};
	}

	#
	# Add to fullfeed:
	$heap->{full}{$sid} = 1;

	$kernel->post( $sid => 'client_print' => 'Full feed enabled, all other functions disabled.');
}

#--------------------------------------------------------------------------#
sub subscribe_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	if( exists $heap->{full}{$sid} ) {  return;  }

	my @progs = map { lc } split /[\s,]+/, $argstr;
	foreach my $prog (@progs) {
		$heap->{subscribers}{$prog}{$sid} = 1;
	}

	$kernel->post( $sid => 'client_print' => 'Subscribed to : ' . join(', ', @progs ) );
}
#--------------------------------------------------------------------------#
sub unsubscribe_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	my @progs = map { lc } split /[\s,]+/, $argstr;
	foreach my $prog (@progs) {
		delete $heap->{subscribers}{$prog}{$sid};
	}

	$kernel->post( $sid => 'client_print' => 'Subscription removed for : ' . join(', ', @progs ) );
}

#--------------------------------------------------------------------------#
sub match_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	if( exists $heap->{full}{$sid} ) {  return;  }

	my @words = map { lc } split /[\s,]+/, $argstr;
	foreach my $word (@words) {
		$heap->{match}{$word}{$sid} = 1;
	}

	$kernel->post( $sid => 'client_print' => 'Receiving messages matching : ' . join(', ', @words ) );
}
#--------------------------------------------------------------------------#
sub nomatch_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	my @words = map { lc } split /[\s,]+/, $argstr;
	foreach my $word (@words) {
		delete $heap->{match}{$word}{$sid};
		# Remove the word from searching if this was the last client
		delete $heap->{match}{$word} unless keys %{ $heap->{match}{$word} };
	}


	$kernel->post( $sid => 'client_print' => 'No longer receving messages matching : ' . join(', ', @words ) );
}
#--------------------------------------------------------------------------#
sub hangup_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	delete $heap->{clients}{$sid};

	foreach my $p ( keys %{ $heap->{subscribers} } ) {
		delete $heap->{subscribers}{$p}{$sid}
			if exists $heap->{subscribers}{$p}{$sid};
	}

	foreach my $word ( keys %{ $heap->{match} } ) {
		delete $heap->{match}{$word}{$sid}
			if exists $heap->{match}{$word}{$sid};
		# Remove the word from searching if this was the last client
		delete $heap->{match}{$word} unless keys %{ $heap->{match}{$word} };
	}


	if( exists $heap->{debug}{$sid} ) {
		delete $heap->{debug}{$sid};
	}

	if( exists $heap->{full}{$sid} ) {
		delete $heap->{full}{$sid};
	}

	debug("Client Termination Posted: $sid\n");

}


#--------------------------------------------------------------------------#
sub stream_start {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	$kernel->alias_set( 'stream' );

	#
	# Initialize the connection to STDIN as a POE::Wheel
	my $stdin = IO::Handle->new_from_fd( \*STDIN, 'r' );
	my $stderr = IO::Handle->new_from_fd( \*STDERR, 'w' );

	$heap->{stream} = POE::Wheel::ReadWrite->new(
		InputHandle		=> $stdin,
		OutputHandle	=> $stderr,
		InputEvent		=> 'stream_line',
		ErrorEvent		=> 'stream_error',
	);
}


#--------------------------------------------------------------------------#
sub stream_line {
	my ($kernel,$msg) = @_[KERNEL,ARG0];

	return unless length $msg;

	$kernel->post( 'dispatcher' => 'dispatch_message' => $msg );

}

#--------------------------------------------------------------------------#
sub stream_error {
	my ($kernel) = $_[KERNEL];

	debug("STREAM ERROR!!!!!!!!!!\n");
	$kernel->call( 'dispatcher' => 'server_shutdown' => 'Stream lost' );
}



#--------------------------------------------------------------------------#
sub server_shutdown {
	my ($kernel,$heap,$msg) = @_[KERNEL,HEAP,ARG0];

	$kernel->call( dispatcher => 'broadcast' => 'SERVER DISCONNECTING: ' . $msg );
	$kernel->call( 'server' => 'shutdown' );
	exit;
}


#--------------------------------------------------------------------------#
sub client_connect {
	my ($kernel,$heap,$ses) = @_[KERNEL,HEAP,SESSION];

	my $KID = $kernel->ID();
	my $CID = $heap->{client}->ID;
	my $SID = $ses->ID;

	$kernel->post( 'dispatcher' => 'register_client' => $SID );

	$heap->{clients}{ $SID } = $heap->{client};
	#
	# Say hello to the client.
	$heap->{client}->put( "EHLO Streamer (KERNEL: $KID:$SID)" );
}

#--------------------------------------------------------------------------#
sub client_print {
	my ($kernel,$heap,$ses,$mesg) = @_[KERNEL,HEAP,SESSION,ARG0];

	$heap->{clients}{$ses->ID}->put($mesg);
}

#--------------------------------------------------------------------------#
sub broadcast {
	my ($kernel,$heap,$msg) = @_[KERNEL,HEAP,ARG0];

	foreach my $sid (keys %{ $heap->{clients} }) {
		$kernel->post( $sid => 'client_print' => $msg );
	}
}
#--------------------------------------------------------------------------#
sub dispatch_message {
	my ($kernel,$heap,$msg) = @_[KERNEL,HEAP,ARG0];

	foreach my $sid ( keys %{ $heap->{full} } ) {
		$kernel->post( $sid => 'client_print' => $msg );
	}

	# Program based subscriptions
	if( my ($program) = map { lc } ($msg =~ /$cooked{program}/) ) {
		# remove the sub process and PID from the program
		$program =~ s/\(.*//g;
		$program =~ s/\[.*//g;

		debug("DISPATCHING MESSAGE [$program]");

		if( exists $heap->{subscribers}{$program} ) {
			foreach my $sid (keys %{ $heap->{subscribers}{$program} }) {
				$kernel->post( $sid => 'client_print' => $msg );
			}
		}
		else {
			debug("Message discarded, no listeners.");
		}
	}

	# Match based subscriptions
	if( keys %{ $heap->{match} } ) {
		foreach my $word (keys %{ $heap->{match} } ) {
			if( index( $msg, $word ) != -1 ) {
				foreach my $sid ( keys %{ $heap->{match}{$word} } ) {
					$kernel->post( $sid => 'client_print' => $msg );
				}
			}
		}
	}
}

#--------------------------------------------------------------------------#
sub debug_message {
	my ($kernel,$heap,$msg) = @_[KERNEL,HEAP,ARG0];


	foreach my $sid (keys %{ $heap->{debug} }) {
		$kernel->post( $sid => 'client_print' => '[debug] ' . $msg );
	}
}


#--------------------------------------------------------------------------#
sub client_input {
	my ($kernel,$heap,$ses,$msg) = @_[KERNEL,HEAP,SESSION,ARG0];
	my $sid = $ses->ID;

	if( !exists $heap->{dispatch}{$sid} ) {
		$heap->{dispatch}{$sid} = {
			fullfeed		=> {
				re			=> qr/^(fullfeed)/,
				callback	=> sub {
					$kernel->post( 'dispatcher' => 'fullfeed_client' => $sid );
				},
			},
			subscribe		=> {
				re			=> qr/^sub(?:scribe)? (.*)/,
				callback	=> sub {
					$kernel->post( 'dispatcher' => 'subscribe_client' => $sid, shift );
				},
			},
			unsubscribe 	=> {
				re			=> qr/^unsub(?:scribe)? (.*)/,
				callback	=> sub {
					$kernel->post( 'dispatcher' => 'unsubscribe_client' => $sid, shift );
				},
			},
			match 	=> {
				re			=> qr/^match (.*)/i,
				callback	=> sub {
					$kernel->post( 'dispatcher' => 'match_client' => $sid, shift );
				},
			},
			nomatch 	=> {
				re			=> qr/^nomatch (.*)/i,
				callback	=> sub {
					$kernel->post( 'dispatcher' => 'nomatch_client' => $sid, shift );
				},
			},
			debug 	=> {
				re			=> qr/^(debug)/i,
				callback	=> sub {
					$kernel->post( 'dispatcher' => 'debug_client' => $sid, shift );
				},
			},
			nobug 	=> {
				re			=> qr/^(no(de)?bug)/i,
				callback	=> sub {
					$kernel->post( 'dispatcher' => 'nobug_client' => $sid, shift );
				},
			},
			#quit			=> {
			#	re			=> qr/(exit)|q(uit)?/,
			#	callback	=> sub {
			#			$kernel->post( $sid => 'client_print' => 'Terminating connection on your request.');
			#			$kernel->post( $sid => 'shutdown' );
			#	},
			#},
			#status			=> {
			#	re			=> qr/^status/,
			#	callback	=> sub {
			#		my $cnt = scalar( keys %{ $heap->{clients} } );
			#		my $subcnt = scalar( keys %{ $heap->{subscribers} });
			#		my $msg = "Currently $cnt connections, $subcnt subscribed.";
			#		$kernel->post( $sid, 'client_print', $msg );
			#	},
			#},
		};
	}

	#
	# Check for messages:
	my $handled = 0;
	my $dispatch = $heap->{dispatch}{$sid};
	foreach my $evt ( keys %{ $dispatch } ) {
		if( my($args) = ($msg =~ /$dispatch->{$evt}{re}/)) {
			$handled = 1;
			$dispatch->{$evt}{callback}->($args);
			last;
		}
	}

	if( !$handled ) {
		$kernel->post( $sid => 'client_print' => 'UNKNOWN COMMAND, Ignored.' );
	}
}

#--------------------------------------------------------------------------#
sub client_term {
	my ($kernel,$heap,$ses) = @_[KERNEL,HEAP,SESSION];
	my $sid = $ses->ID;

	delete $heap->{dispatch}{$sid};
	$kernel->post( 'dispatcher' => 'hangup_client' =>  $sid );

	debug("SERVER, client $sid disconnected.\n");
}


#--------------------------------------------------------------------------#
