package POE::Component::EasyDBI;

use strict;
use warnings FATAL =>'all';

# Initialize our version
our $VERSION = (qw($Revision: 0.04 $))[1];

# Import what we need from the POE namespace
use POE;
use POE::Session;
use POE::Filter::Reference;
use POE::Filter::Line;
use POE::Wheel::Run;
use POE::Component::EasyDBI::SubProcess;

# Miscellaneous modules
use Carp;

sub MAX_RETRIES () { 5 }
sub DEBUG () { 0 }

# Autoflush on STDOUT
# Select returns last selected handle
# So, reselect it after selecting STDOUT and setting Autoflush
select((select(STDOUT), $| = 1)[0]);

# Set things in motion!
sub new {
	# Get the OOP's type
	my $type = shift;

	# Sanity checking
	if ( @_ & 1 ) {
		croak( 'POE::Component::EasyDBI requires an even number of options passed to new() call' );
	}

	# The options hash
	my %opt = @_;

	# lowercase keys
	%opt = map { lc($_) => $opt{$_} } keys %opt;
	
	# Our own options
	my ( $DSN, $ALIAS, $USERNAME, $PASSWORD, $MAX_RETRIES );

	# Get the DSN
	# username/password/port other options
	# should be part of the DSN
	if ( exists $opt{'dsn'} ) {
		$DSN = $opt{'dsn'};
		delete $opt{'dsn'};
	} else {
		croak( 'DSN is required to create a new POE::Component::EasyDBI instance!' );
	}

	# Get the USERNAME
	if ( exists $opt{username} ) {
		$USERNAME = $opt{username};
		delete $opt{username};
	} else {
		croak( 'username is required to create a new POE::Component::EasyDBI instance!' );
	}

	# Get the PASSWORD
	if ( exists $opt{password} ) {
		$PASSWORD = $opt{password};
		delete $opt{password};
	} else {
		croak( 'password is required to create a new POE::Component::EasyDBI instance!' );
	}

	# Get the session alias
	if ( exists $opt{'alias'} ) {
		$ALIAS = $opt{'alias'};
		delete $opt{'alias'};
	} else {
		# Debugging info...
		if ( DEBUG ) {
			warn 'Using default Alias EasyDBI';
		}

		# Set the default
		$ALIAS = 'EasyDBI';
	}

	# Get the max retries
	if ( exists $opt{'max_retries'} ) {
		$MAX_RETRIES = $opt{'max_retries'};
		delete $opt{'max_retries'};
	}

	# Anything left over is unrecognized
	if (keys %opt) {
		croak( 'Unrecognized keys/options ('.join(',',(keys %opt)).') were present in new() call to POE::Component::EasyDBI!' );
	}

	# Create a new session for ourself
	POE::Session->create(
		# Our subroutines
		'inline_states'	=>	{
			# Maintenance events
			'_start'		=>	\&start,
			'_stop'			=>	\&stop,
			'setup_wheel'	=>	\&setup_wheel,
			'shutdown'		=>	\&shutdown_poco,

			# child events
			'child_error'	=>	\&child_error,
			'child_closed'	=>	\&child_closed,
			'child_STDOUT'	=>	\&child_STDOUT,
			'child_STDERR'	=>	\&child_STDERR,

			# database events
			'DO'			=>	\&db_handler,
			'do'			=>	\&db_handler,
			
			'SINGLE'		=>	\&db_handler,
			'single'		=>	\&db_handler,
			
			'QUOTE'			=>	\&db_handler,
			'quote'			=>	\&db_handler,
			
			'ARRAYHASH'		=>	\&db_handler,
			'arrayhash'		=>	\&db_handler,
			
			'HASHHASH'		=>	\&db_handler,
			'hashhash'		=>	\&db_handler,
			
			'HASHARRAY'		=>	\&db_handler,
			'hasharray'		=>	\&db_handler,
			
			'ARRAY'			=>	\&db_handler,
			'array'			=>	\&db_handler,
			
			'HASH'			=>	\&db_handler,
			'hash'			=>	\&db_handler,
			
			'KEYVALHASH'	=>	\&db_handler,
			'keyvalhash'	=>	\&db_handler,
			
			# Queue handling
			'send_query'	=>	\&send_query,
			'check_queue'	=>	\&check_queue,
		},

		# Set up the heap for ourself
		'heap'	=>	{
			# The queue of DBI calls
			'queue'			=>	[],
			'idcounter'		=>	0,

			# The Wheel::Run object
			'wheel'			=>	undef,

			# How many times have we re-created the wheel?
			'retries'		=>	0,

			# Are we shutting down?
			'shutdown'		=>	0,

			# The DB Info
			'dsn'			=>	$DSN,
			'username'		=>	$USERNAME,
			'password'		=>	$PASSWORD,

			# The alia/s we will run under
			'alias'			=>	$ALIAS,

			'max_retries'	=> $MAX_RETRIES || MAX_RETRIES,
		},
	) or die 'Unable to create a new session!';

	# Return success
	return 1;
}
 
# This subroutine handles shutdown signals
sub shutdown_poco {
	my ($kernel, $heap) = @_[KERNEL,HEAP];
	
	# Check for duplicate shutdown signals
	if ( $heap->{shutdown} ) {
		# Okay, let's see what's going on
		if ( $heap->{shutdown} == 1 && ! defined $_[ARG0] ) {
			# Duplicate shutdown events
			if (DEBUG) {
				warn 'Duplicate shutdown event fired!';
			}
			return;
		} elsif ( $heap->{shutdown} == 2 ) {
			# Tried to shutdown_NOW again...
			if (DEBUG) {
				warn 'Duplicate shutdown NOW fired!';
			}
			return;
		}
	} else {
		# Remove our alias so we can be properly terminated
		$kernel->alias_remove( $heap->{alias} );
	}

	# Check if we got "NOW"
	if ( defined $_[ARG0] && uc($_[ARG0]) eq 'NOW' ) {
		# Actually shut down!
		$heap->{shutdown} = 2;

		# KILL our subprocess
		$heap->{wheel}->kill( -9 );

		# Delete the wheel, so we have nothing to keep the GC from destructing us...
		delete $heap->{wheel};

		# Go over our queue, and do some stuff
		foreach my $queue ( @{ $heap->{queue} } ) {
			# Skip the special EXIT actions we might have put on the queue
			if ( $queue->{action} eq 'EXIT' ) { next }

			# Post a failure event to all the queries on the Queue, informing them that we have been shutdown...
			$kernel->post( $queue->{session}, $queue->{event}, {
				sql				=>	$queue->{sql},
				placeholders	=>	$queue->{placeholders},
				error			=>	'POE::Component::EasyDBI was shut down forcibly!',
				},
			);

			# Argh, decrement the refcount
			$kernel->refcount_decrement( $queue->{session}, 'EasyDBI' );
		}

		# Tell the kernel to kill us!
		$kernel->signal( $_[SESSION], 'KILL' );
	} else {
		# Gracefully shut down...
		$heap->{shutdown} = 1;

		# Put into the queue EXIT for the child
		$kernel->yield( 'send_query', {
			action			=>	'EXIT',
			sql				=>	undef,
			placeholders	=>	undef,
			}
		);
	}
}

# This subroutine handles queries
sub db_handler {
	my ($kernel, $heap) = @_[KERNEL,HEAP];

	# Get the arguments
	my $args;
	if (ref($_[ARG0]) eq 'HASH') {
		$args = { %{ $_[ARG0] } };
	} else {
		warn "first parameter must be a ref hash, trying to adjust. (fix this to get rid of this message)";
		$args = { @_[ARG0 .. $#_ ] };
	}

	# Add some stuff to the args
	# defaults to sender, but can be specified
	unless ($args->{session}) {
		$args->{session} = $_[SENDER]->ID();
	}
	
	$args->{action} = $_[STATE];

	if ( ! exists $args->{event} ) {
		# Nothing much we can do except drop this quietly...
		warn "Did not receive an event argument from caller " . $_[SESSION]->ID . " -> State: " . $_[STATE] . " Args: " . %$args;
		return;
	} else {
		if ( ref( $args->{event} ne 'SCALAR' ) ) {
			# Same quietness...
			warn "Received an malformed event argument from caller " . $_[SESSION]->ID . " -> State: " . $_[STATE] . " Args: " . %$args;
			return;
		}
	}

	if ( ! exists $args->{sql} ) {
		# Okay, send the error to the Failure Event
		$kernel->post( $args->{session}, $args->{event}, {
			sql				=>	undef,
			placeholders	=>	undef,
			error			=>	'sql is not defined!',
			}
		);
		return;
	} else {
		if ( ref( $args->{sql} ) ) {
			# Okay, send the error to the Failure Event
			$kernel->post( $args->{session}, $args->{event}, {
				sql				=>	undef,
				placeholders	=>	undef,
				error			=>	'sql is not a scalar!',
				}
			);
			return;
		}
	}

	# Check for placeholders
	if ( ! exists $args->{placeholders} ) {
		# Create our own empty placeholders
		$args->{placeholders} = [];
	} else {
		if ( ref( $args->{placeholders} ) ne 'ARRAY' ) {
			# Okay, send the error to the Failure Event
			$kernel->post( $args->{session}, $args->{event}, {
				sql				=>	$args->{sql},
				placeholders	=>	undef,
				error			=>	'placeholders is not an array!',
				}
			);
			return;
		}
	}

	# Check for primary_key on HASHHASH or ARRAYHASH queries
	if ( $args->{action} eq 'HASHHASH' || $args->{action} eq 'HASHARRAY' ) {
		if (!exists $args->{primary_key}) {
			$kernel->post( $args->{session}, $args->{event}, {
				sql				=>	$args->{sql},
				placeholders	=>	undef,
				error			=>	'primary_key is not defined! It must be a column name or a 1 based index of a column',
				}
			);
			return;
		} else {
			if ( ref( $args->{sql} ) ) {
				# Okay, send the error to the Failure Event
				$kernel->post( $args->{session}, $args->{event}, {
					sql				=>	undef,
					placeholders	=>	undef,
					error			=>	'primary_key is not a scalar!',
					}
				);
				return;
			}
		}
	}

	# Check if we have shutdown or not
	if ( $heap->{shutdown} ) {
		# Do not accept this query
		$kernel->post( $args->{session}, $args->{event}, {
			sql				=>	$args->{sql},
			placeholders	=>	$args->{placeholders},
			error			=>	'POE::Component::EasyDBI is shutting down now, requests are not accepted!',
			}
		);
		return;
	}

	# Increment the refcount for the session that is sending us this query
	$kernel->refcount_increment( $_[SENDER]->ID(), 'EasyDBI' );

	# Okay, fire off this query!
	$kernel->yield( 'send_query', $args );
}

# This subroutine starts the process of sending a query
sub send_query {
	my ($kernel, $heap, $args) = @_[KERNEL,HEAP,ARG0];
	
	# Validate that we have something
	if (!defined($args) || ref($args) ne 'HASH') {
		return;
	}

	# Add the ID to the query
	$args->{id} = $heap->{idcounter}++;

	# Add this query to the queue
	push( @{ $heap->{queue} }, { %{ $args } } );

	# Send the query!
	$kernel->call( $_[SESSION], 'check_queue' );
}

# This subroutine does the meat - sends queries to the subprocess
sub check_queue {
	my ($kernel, $heap) = @_[KERNEL,HEAP];
	
	# Check if the subprocess is currently active
	if ( ! $heap->{active} ) {
		# Check if we have a query in the queue
		if ( scalar( @{ $heap->{queue} } ) > 0 ) {
			# Copy what we need from the top of the queue
			my %queue;
			$queue{id} = @{ $heap->{queue} }[0]->{id};
			$queue{sql} = @{ $heap->{queue} }[0]->{sql};
			$queue{action} = @{ $heap->{queue} }[0]->{action};
			$queue{placeholders} = @{ $heap->{queue} }[0]->{placeholders};
			# check for primary_key
			if (exists(@{ $heap->{queue} }[0]->{primary_key})) {
				$queue{primary_key} = @{ $heap->{queue} }[0]->{primary_key};
			}
			# chunked
			if (exists(@{ $heap->{queue} }[0]->{chunked})) {
				$queue{chunked} = @{ $heap->{queue} }[0]->{chunked};
			}
			# and seperator
			if (exists(@{ $heap->{queue} }[0]->{seperator})) {
				$queue{seperator} = @{ $heap->{queue} }[0]->{seperator};
			}

			# Send data only if we are not shutting down...
			if ( $heap->{shutdown} != 2 ) {
				# Set the child to 'active'
				$heap->{active} = 1;
		
				# Put it in the wheel
				$heap->{wheel}->put( \%queue );
			}
		}
	}
}

# This starts the EasyDBI
sub start {
	my ($kernel, $heap) = @_[KERNEL,HEAP];
	
	# Set up the alias for ourself
	$kernel->alias_set( $heap->{alias} );

	# Create the wheel
	$kernel->yield( 'setup_wheel' );
}

# This sets up the WHEEL
sub setup_wheel {
	my ($kernel, $heap) = @_[KERNEL,HEAP];
	
	# Are we shutting down?
	if ( $heap->{shutdown} ) {
		# Do not re-create the wheel...
		return;
	}

	# Check if we should set up the wheel
	if ( $heap->{retries} == $heap->{max_retries} ) {
		die 'POE::Component::EasyDBI tried ' . $heap->{max_retries} . ' times to create a Wheel and is giving up...';
	}

	# Set up the SubProcess we communicate with
	$heap->{wheel} = POE::Wheel::Run->new(
		# What we will run in the separate process
		'Program'		=>	\&POE::Component::EasyDBI::SubProcess::main,
		'ProgramArgs'	=>	[ $heap->{dsn}, $heap->{username}, $heap->{password} ],

		# Kill off existing FD's
		'CloseOnCall'	=>	1,

		# Redirect errors to our error routine
		'ErrorEvent'	=>	'child_error',

		# Send child died to our child routine
		'CloseEvent'	=>	'child_closed',

		# Send input from child
		'StdoutEvent'	=>	'child_STDOUT',

		# Send input from child STDERR
		'StderrEvent'	=>	'child_STDERR',

		# Set our filters
		'StdinFilter'	=>	POE::Filter::Reference->new(),		# Communicate with child via Storable::nfreeze
		'StdoutFilter'	=>	POE::Filter::Reference->new(),		# Receive input via Storable::nfreeze
		'StderrFilter'	=>	POE::Filter::Line->new(),		# Plain ol' error lines
	);

	# Check for errors
	if ( ! defined $heap->{wheel} ) {
		die 'Unable to create a new wheel!';
	} else {
		# Increment our retry count
		$heap->{retries}++;

		# Set the wheel to inactive
		$heap->{active} = 0;

		# Check for queries
		$kernel->call( $_[SESSION], 'check_queue' );
	}
}

# Stops everything we have
sub stop {
	# nothing to see here, move along
}

# Deletes a query from the queue, if it is not active
sub delete_query {
	my ($kernel, $heap) = @_[KERNEL,HEAP];
	# ARG0 = ID
	my $id = $_[ARG0];

	# Validation
	if ( ! defined $id ) {
		# Debugging
		if ( DEBUG ) {
			warn 'In Delete_Query event with no arguments!';
		}
		return;
	}

	# Check if the id exists + not at the top of the queue :)
	if ( defined @{ $heap->{queue} }[0] ) {
		if ( @{ $heap->{queue} }[0]->{id} eq $id ) {
			# Query is still active, nothing we can do...
			return undef;
		} else {
			# Search through the rest of the queue and see what we get
			foreach my $count ( @{ $heap->{queue} } ) {
				if ( $heap->{queue}->[ $count ]->{id} eq $id ) {
					# Found a match, delete it!
					splice( @{ $heap->{queue} }, $count, 1 );

					# Return success
					return 1;
				}
			}
		}
	}

	# If we got here, we didn't find anything
	return undef;
}

# Handles child DIE'ing
sub child_closed {
	my ($kernel, $heap) = @_[KERNEL,HEAP];
	
	# Emit debugging information
	if ( DEBUG ) {
		warn 'POE::Component::EasyDBI\'s Wheel died! Restarting it...';
	}

	# Create the wheel again
	delete $heap->{wheel};
	$kernel->call( $_[SESSION], 'setup_wheel' );
}

# Handles child error
sub child_error {
	# Emit warnings only if debug is on
	if ( DEBUG ) {
		# Copied from POE::Wheel::Run manpage
		my ( $operation, $errnum, $errstr ) = @_[ ARG0 .. ARG2 ];
		warn "POE::Component::EasyDBI got an $operation error $errnum: $errstr\n";
	}
}

# Handles child STDOUT output
sub child_STDOUT {
	my ($kernel, $heap, $data) = @_[KERNEL,HEAP,ARG0];
	
	# Validate the argument
	if ( ref( $data ) ne 'HASH' ) {
		warn "POE::Component::EasyDBI did not get a hash from the child ( $data )";
		return;
	}

	# Check for special DB messages with ID of 'DBI'
	if ( $data->{id} eq 'DBI' ) {
		# Okay, we received a DBI error -> error in connection...

		# Shutdown ourself!
		$kernel->call( $_[SESSION], 'shutdown', 'NOW' );

		# Too bad that we have to die...
		croak( "Could not connect to DBI: $data->{error}" );
	}

	my $query;
	my $refcount_decrement = 0;
	
	if (exists($data->{chunked})) {
				
		# Get the query from the queue
		for my $i ( 0 .. $#{ $heap->{queue} } ) {
			if ($heap->{queue}[$i]->{id} eq $data->{id}) {
				$query = $heap->{queue}[$i];
				if (exists($data->{last_chunk})) {
					# last chunk, delete it out of the queue
					splice( @{ $heap->{queue} }, $i, 1 );
					$refcount_decrement = 1;
				}
				last;
			}
		}
		unless ( defined $query ) {
			warn "Internal error in queue/child consistency! Chunk query not found in queue ( CHILD: $data->{id} ) Please notify author!";
		}
		
	} else {
		# Check to see if the ID matches with the top of the queue
		if ( $data->{id} ne @{ $heap->{queue} }[0]->{id} ) {
			die "Internal error in queue/child consistency! ( CHILD: $data->{id} QUEUE: @{ $heap->{queue} }[0]->{id} )";
		}
		# Get the query from the top of the queue
		$query = shift( @{ $heap->{queue} } );
		$refcount_decrement = 1;
	}

	# copy the query data, so we don't clobber the
	# stored data when using chunks
	my $query_copy = { %{ $query } };
	
	# marry data from the child to the data from the queue
	foreach my $k (keys %$data) {
		$query_copy->{$k} = $data->{$k};
	}
	
	$kernel->post( $query->{session}, $query->{event}, $query_copy );

	# Decrement the refcount for the session that sent us a query
	if ($refcount_decrement == 1) {
		$heap->{active} = 0;
		$kernel->refcount_decrement( $query->{session}, 'EasyDBI' );

		# Now, that we have got a result, check if we need to send another query
		$kernel->call( $_[SESSION], 'check_queue' );
	}

}

# Handles child STDERR output
sub child_STDERR {
	my $input = $_[ARG0];

	# Skip empty lines as the POE::Filter::Line manpage says...
	if ( $input eq '' ) { return }

	warn "POE::Component::EasyDBI Got STDERR from child, which should never happen ( $input )";
}

# End of module
1;

__END__

=head1 NAME

POE::Component::EasyDBI - Perl extension for asynchronous non-blocking DBI calls in POE

=head1 SYNOPSIS

	use POE;
	use POE::Component::EasyDBI;

	# Set up the DBI
	POE::Component::EasyDBI->new(
		alias		=> 'EasyDBI',
		dsn			=> 'DBI:mysql:database=foobaz;host=192.168.1.100;port=3306',
		username	=> 'user',
		password	=> 'pass',
	);

	# Create our own session to communicate with EasyDBI
	POE::Session->create(
		inline_states => {
			_start => sub {
				$kernel->post( 'EasyDBI',
					do => {
						sql => 'DELETE FROM users WHERE user_id = ?',
						placeholders => [ qw( 144 ) ],
						event => 'deleted_handler',
					}
				);

				# 'single' is very different from the single query in SimpleDBI
				# look at 'hash' to get those results
				
				# If you select more than one field, you will only get the last one
				# unless you pass in a seperator with what you want the fields seperated by
				# to get null sperated values, pass in seperator => "\0"
				$kernel->post( 'EasyDBI',
					single => {
						sql => 'Select user_id,user_login from users where user_id = ?',
						event => 'single_handler',
						placeholders => [ qw( 144 ) ],
						seperator => ',', #optional!
					}
				);

				$kernel->post( 'EasyDBI',
					quote => {
						sql => 'foo$*@%%sdkf"""',
						event => 'quote_handler',
					}
				);
				
				$kernel->post( 'EasyDBI',
					arrayhash => {
						sql => 'SELECT user_id,user_login from users where logins = ?',
						event => 'arrayhash_handler',
						placeholders => [ qw( 53 ) ],
					}
				);
				
				my $postback = $_[SESSION]->postback("test",3,2,1);
				
				$_[KERNEL]->post( 'EasyDBI',
					arrayhash => {
						sql => 'SELECT user_id,user_login from users',
						event => 'result_handler',
						extra_data => $postback,
					}
				);

				$_[KERNEL]->post( 'EasyDBI',
					hashhash => {
						sql => 'SELECT * from locations',
						event => 'result_handler',
						primary_key => '1', # you can specify a primary key, or a number based on what column to use
					}
				);
				
				$_[KERNEL]->post( 'EasyDBI',
					hasharray => {
						sql => 'SELECT * from locations',
						event => 'result_handler',
						primary_key => "1",
					}
				);
				
				# you should use limit 1, it is NOT automaticly added
				$_[KERNEL]->post( 'EasyDBI',
					hash => {
						sql => 'SELECT * from locations LIMIT 1',
						event => 'result_handler',
					}
				);
				
				$_[KERNEL]->post( 'EasyDBI',
					array => {
						sql => 'SELECT location_id from locations',
						event => 'result_handler',
					}
				);
				
				$_[KERNEL]->post( 'EasyDBI',
					keyvalhash => {
						sql => 'SELECT location_id,location_name from locations',
						event => 'result_handler',
					}
				);
				# 3 ways to shutdown

				# This will let the existing queries finish, then shutdown
				$kernel->post( 'EasyDBI', 'shutdown' );

				# This will terminate when the event traverses
				# POE's queue and arrives at EasyDBI
				#$kernel->post( 'EasyDBI', shutdown => 'NOW' );

				# Even QUICKER shutdown :)
				#$kernel->call( 'EasyDBI', shutdown => 'NOW' );
			},

			deleted_handler => \&deleted_handler,
			quote_handler	=> \&quote_handler,
			arrayhash_handler => \&arrayhash_handler,
		},
	);

	sub quote_handler {
		# For QUOTE calls, we receive the scalar string of SQL quoted
		# $_[ARG0] = {
		#	sql => The SQL you sent
		#	result	=> scalar quoted SQL
		#	placeholders => The placeholders
		#	action => 'QUOTE'
		#	error => Error occurred, check this first
		# }
	}

	sub deleted_handler {
		# For DO calls, we receive the scalar value of rows affected
		# $_[ARG0] = {
		#	sql => The SQL you sent
		#	result	=> scalar value of rows affected
		#	placeholders => The placeholders
		#	action => 'do'
		#	error => Error occurred, check this first
		# }
	}

	sub single_handler {
		# For SINGLE calls, we receive a scalar
		# $_[ARG0] = {
		#	SQL => The SQL you sent
		#	result	=> scalar
		#	placeholders => The placeholders
		#	action => 'single'
		#	seperator => Seperator you may have sent
		#	error => Error occurred, check this first
		# }
	}

	sub arrayhash_handler {
		# For arrayhash calls, we receive an array of hashes
		# $_[ARG0] = {
		#	sql => The SQL you sent
		#	result	=> array of hashes
		#	placeholders => The placeholders
		#	action => 'arrayhash'
		#	error => Error occurred, check this first
		# }
	}

	sub hashhash_handler {
		# For hashhash calls, we receive a hash of hashes
		# $_[ARG0] = {
		#	sql => The SQL you sent
		#	result	=> hash of hashes keyed on primary key
		#	placeholders => The placeholders
		#	action => 'hashhash'
		#	cols => array of columns in order (to help recreate the sql order)
		#	primary_key => column you specified as primary key, if you specifed a number, the real column name will be here
		#	error => Error occurred, check this first
		# }
	}

	sub hasharray_handler {
		# For hasharray calls, we receive an hash of arrays
		# $_[ARG0] = {
		#	sql => The SQL you sent
		#	result	=> hash of hashes keyed on primary key
		#	placeholders => The placeholders
		#	action => 'hashhash'
		#	cols => array of columns in order (to help recreate the sql order)
		#	primary_key => column you specified as primary key, if you specifed a number, the real column name will be here
		#	error => Error occurred, check this first
		# }
	}
	
	sub array_handler {
		# For array calls, we receive an array
		# $_[ARG0] = {
		#	sql => The SQL you sent
		#	result	=> an array, if multiple fields are used, they are comma seperated (specify seperator in event call to change this)
		#	placeholders => The placeholders
		#	action => 'array'
		#	seperator => you sent  # optional!
		#	error => Error occurred, check this first
		# }
	}
	
	sub hash_handler {
		# For hash calls, we receive a hash
		# $_[ARG0] = {
		#	sql => The SQL you sent
		#	result	=> a hash
		#	placeholders => The placeholders
		#	action => 'hash'
		#	error => Error occurred, check this first
		# }
	}

	sub keyvalhash_handler {
		# For keyvalhash calls, we receive a hash
		# $_[ARG0] = {
		#	sql => The SQL you sent
		#	result	=> a hash  # first field is the key, second field is the value
		#	placeholders => The placeholders
		#	action => 'keyvalhash'
		#	error => Error occurred, check this first
		# }
	}

=head1 ABSTRACT

	This module simplifies DBI usage in POE's multitasking world.

	This module is easy to use, you'll have DBI calls in your POE program
	up and running in no time.

=head1 DESCRIPTION

This module works by creating a new session, then spawning a child process to do
the DBI querys. That way, your main POE process can continue servicing other clients.

The standard way to use this module is to do this:

	use POE;
	use POE::Component::EasyDBI;

	POE::Component::EasyDBI->new( ... );

	POE::Session->create( ... );

	POE::Kernel->run();

=head2 Starting EasyDBI

To start EasyDBI, just call it's new method.

This one is for Postgresql:

	POE::Component::EasyDBI->new(
		alias		=> 'EasyDBI',
		dsn			=> 'DBI:Pg:dbname=test;host=10.0.1.20',
		username	=> 'user',
		password	=> 'pass',
	);

This one is for mysql:

	POE::Component::EasyDBI->new(
		alias		=> 'EasyDBI',
		dsn			=> 'DBI:mysql:database=foobaz;host=192.168.1.100;port=3306',
		username	=> 'user',
		password	=> 'pass',
	);
	
This method will die on error or return success.

Note the difference between dbname and database, that is dependant on the driver used, NOT EasyDBI

NOTE: If the SubProcess could not connect to the DB, it will return an error, causing EasyDBI to croak/die.

This constructor accepts 6 different options.

=over 4

=item C<alias>

This will set the alias EasyDBI uses in the POE Kernel.
This will default TO "EasyDBI"

=item C<dsn>

This is the DSN (Database connection string)

EasyDBI expects this to contain everything you need to connect to a database
via DBI, without the username and password.

For valid DSN strings, contact your DBI driver's manual.

=item C<username>

This is the DB username EasyDBI will use when making the call to connect

=item C<password>

This is the DB password EasyDBI will use when making the call to connect

=item C<max_retries>

This is the max number of times the database wheel will be restarted, default is 5

=back

=head2 Events

There is only a few events you can trigger in EasyDBI.
They all share a common argument format, except for the shutdown event.


Note: you can change the session that the query posts back to, it uses $_[SENDER]
as the default.

For example:

	$kernel->post( 'EasyDBI',
		quote => {
				sql => 'foo$*@%%sdkf"""',
				event => 'quoted_handler',
				session => 'dbi_helper', # or you can use a session id
		}
	);


=over 4

=item C<quote>

	This sends off a string to be quoted, and gets it back.

	Internally, it does this:

	return $dbh->quote( $SQL );

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		quote => {
			sql => 'foo$*@%%sdkf"""',
			event => 'quoted_handler',
		}
	);

	The Success Event handler will get a hash ref in ARG0:
	{
		sql		=>	Unquoted SQL sent
		result	=>	Quoted SQL
	}

=item C<do>

	This query is for those queries where you UPDATE/DELETE/etc.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $sql );
	$rows_affected = $sth->execute( $placeholders );
	return $rows_affected;

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		do => {
			sql => 'DELETE FROM FooTable WHERE ID = ?',
			placeholders => [ qw( 38 ) ],
			event => 'deleted_handler',
		}
	);

	The Success Event handler will get a hash in ARG0:
	{
		sql				=>	SQL sent
		result			=>	Scalar value of rows affected
		placeholders	=>	Original placeholders
	}

=item C<single>

	This query is for those queries where you will get exactly 1 row and column back.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $sql );
	$sth->bind_columns( %result );
	$sth->execute( $placeholders );
	$sth->fetch();
	return %result;

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		single => {
			sql => 'Select test_id from FooTable',
			event => 'result_handler',
		}
	);

	The Success Event handler will get a hash in ARG0:
	{
		sql				=>	SQL sent
		result			=>	scalar
		placeholders	=>	Original placeholders
	}

=item C<arrayhash>

	This query is for those queries where you will get more than 1 row and column back.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	while ( $row = $sth->fetchrow_hashref() ) {
		push( @results,{ %{ $row } } );
	}
	return @results;

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		arrayhash => {
			sql => 'SELECT this, that FROM my_table WHERE my_id = ?',
			event => 'result_handler',
			placeholders => [ qw( 2021 ) ],
		}
	);

	The Success Event handler will get a hash in ARG0:
	{
		sql				=>	SQL sent
		result			=>	Array of hashes of the rows ( array of fetchrow_hashref's )
		placeholders	=>	Original placeholders
		cols			=>	An array of the cols in query order
	}

=item C<hashhash>

	This query is for those queries where you will get more than 1 row and column back.

	The primary_key should be UNIQUE! If it is not, then use hasharray instead.

	Internally, it does something like this:

	if ($primary_key =~ m/^\d+$/) {
		if ($primary_key} > $sth->{NUM_OF_FIELDS}) {
			die "primary_key is out of bounds";
		}
		$primary_key = $sth->{NAME}->[($primary_key-1)];
	}
	
	for $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
		$col{$sth->{NAME}->[$i]} = $i;
		push(@cols, $sth->{NAME}->[$i]);
	}

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	while ( @row = $sth->fetch_array() ) {
		foreach $c (@cols) {
			$results{$row[$col{$primary_key}]}{$c} = $row[$col{$c}];
		}
	}
	return %results;

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		hashhash => {
			sql => 'SELECT this, that FROM my_table WHERE my_id = ?',
			event => 'result_handler',
			placeholders => [ qw( 2021 ) ],
			primary_key => "2",  # making 'that' the primary key
		}
	);

	The Success Event handler will get a hash in ARG0:
	{
		sql				=>	SQL sent
		result			=>	Hashes of hashes of the rows
		placeholders	=>	Original placeholders
		cols			=>	An array of the cols in query order
	}

=item C<hasharray>

	This query is for those queries where you will get more than 1 row and column back.

	Internally, it does something like this:

	# find the primary key
	if ($primary_key =~ m/^\d+$/) {
		if ($primary_key} > $sth->{NUM_OF_FIELDS}) {
			die "primary_key is out of bounds";
		}
		$primary_key = $sth->{NAME}->[($primary_key-1)];
	}
	
	for $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
		$col{$sth->{NAME}->[$i]} = $i;
		push(@cols, $sth->{NAME}->[$i]);
	}
	
	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	while ( @row = $sth->fetch_array() ) {
		push(@{ $results{$row[$col{$primary_key}}]} }, @row);
	}
	return %results;

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		hasharray => {
			sql => 'SELECT this, that FROM my_table WHERE my_id = ?',
			event => 'result_handler',
			placeholders => [ qw( 2021 ) ],
			primary_key => "1",  # making 'this' the primary key
		}
	);

	The Success Event handler will get a hash in ARG0:
	{
		sql				=>	SQL sent
		result			=>	Hashes of hashes of the rows
		placeholders	=>	Original placeholders
		primary_key		=>	'this' # the column name for the number passed in
		cols			=>	An array of the cols in query order
	}

=item C<array>

	This query is for those queries where you will get more than 1 row with 1 column back.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	while ( @row = $sth->fetchrow_array() ) {
		if ($seperator) {
			push( @results,join($seperator,@row) );
		} else {
			push( @results,join(',',@row) );
		}
	}
	return @results;

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		array => {
			sql => 'SELECT this FROM my_table WHERE my_id = ?',
			event => 'result_handler',
			placeholders => [ qw( 2021 ) ],
			seperator => ',', # default seperator
		}
	);

	The Success Event handler will get a hash in ARG0:
	{
		sql				=>	SQL sent
		result			=>	Array of scalars (joined with seperator if more than one column is returned)
		placeholders	=>	Original placeholders
	}

=item C<hash>

	This query is for those queries where you will get 1 row with more than 1 column back.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	@row = $sth->fetchrow_array();
	if (@row) {
		for $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
			$results{$sth->{NAME}->[$i]} = $row[$i];
		}
	}
	return %results;

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		hash => {
			sql => 'SELECT * FROM my_table WHERE my_id = ?',
			event => 'result_handler',
			placeholders => [ qw( 2021 ) ],
		}
	);

	The Success Event handler will get a hash in ARG0:
	{
		sql				=>	SQL sent
		result			=>	Hash
		placeholders	=>	Original placeholders
	}

=item C<keyvalhash>

	This query is for those queries where you will get 1 row with more than 1 column back.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	while (	@row = $sth->fetchrow_array() ) {
		$results{$row[0]} = $row[1];
	}
	return %results;

	Here's an example on how to trigger this event:

	$kernel->post( 'EasyDBI',
		keyvalhash => {
			sql => 'SELECT this, that FROM my_table WHERE my_id = ?',
			event => 'result_handler',
			placeholders => [ qw( 2021 ) ],
		}
	);

	The Success Event handler will get a hash in ARG0:
	{
		sql				=>	SQL sent
		result			=>	Hash
		placeholders	=>	Original placeholders
	}

=item C<shutdown>

	$kernel->post( 'EasyDBI', 'shutdown' );

	This will signal EasyDBI to start the shutdown procedure.

	NOTE: This will let all outstanding queries run!
	EasyDBI will kill it's session when all the queries have been processed.

	you can also specify an argument:

	$kernel->post( 'EasyDBI', 'shutdown' => 'NOW' );

	This will signal EasyDBI to shutdown.

	NOTE: This will NOT let the outstanding queries finish!
	Any queries running will be lost!

	Due to the way POE's queue works, this shutdown event will take some time to propagate POE's queue.
	If you REALLY want to shut down immediately, do this:

	$kernel->call( 'EasyDBI', 'shutdown' => 'NOW' );

	ALL shutdown NOW's send kill -9 to thier children, beware of any transactions that you may be in.
	Your queries will revert if you are in transaction mode

=back

=head3 Arguments

They are passed in via the $kernel->post( ... );

Note: all query types can be in ALL-CAPS or lowercase but not MiXeD!

ie ARRAYHASH or arrayhash but not ArrayHash


=over 4

=item C<sql>

This is the actual SQL line you want EasyDBI to execute.
You can put in placeholders, this module supports them.

=item C<placeholders>

This is an array of placeholders.

You can skip this if your query does not use placeholders in it.

=item C<event>

This is the success/failure event, triggered whenever a query finished successfully or not.

It will get a hash in ARG0, consult the specific queries on what you will get.

In the case of an error, the key 'error' will have the specific error that occurred

=item C<seperator>

Query types single, and array accept this parameter.
The default is a comma (,) and is optional

If a query has more than 1 column returned, the columns are joined with 'seperator'.

=item C<primary_key>

Query types hashhash, and hasharray accept this parameter.
It is used to key the hash on a certain field

=item C<chunked>

All multi-row queries can be chunked.

You can pass the parameter 'chunked' with a number of rows to fire the 'event' event
for every 'chunked' rows, it will fire the 'event' event. ( a 'chunked' key will exist )
A 'last_chunk' key will exist when you have received the last chunk of data from the query

=back

=head2 EasyDBI Notes

This module is very picky about capitalization!

All of the options are in lowercase.  Query types can be in ALL-CAPS or lowercase.

This module will try to keep the SubProcess alive.
if it dies, it will open it again for a max of 5 retries by
default, but you can override this behavior by doing something like this:

POE::Component::EasyDBI->new( max_retries => 3 );

=head2 EXPORT

Nothing.

=head1 SEE ALSO

L<DBI>

L<POE>

L<POE::Wheel::Run>

L<POE::Component::DBIAgent>

L<POE::Component::LaDBI>

L<POE::Component::SimpleDBI>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 CREDITS

Apocalypse E<lt>apocal@cpan.orgE<gt>
for POE::Component::SimpleDBI the basis of this PoCo

=head1 COPYRIGHT AND LICENSE

Copyright 2003 by David Davis and Teknikill Software

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
