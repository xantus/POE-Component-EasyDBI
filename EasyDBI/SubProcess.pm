package POE::Component::EasyDBI::SubProcess;

use strict;
use warnings FATAL => 'all';

# Initialize our version
our $VERSION = (qw($Revision: 0.02 $))[1];

# Use Error.pm's try/catch semantics
use Error qw( :try );

# We pass in data to POE::Filter::Reference
use POE::Filter::Reference;

# We run the actual DB connection here
use DBI;

# Our Filter object
my $filter = POE::Filter::Reference->new();

# Autoflush to avoid weirdness
$|++;

# This is the subroutine that will get executed upon the fork() call by our parent
sub main {
	# Get our args
	my ( $DSN, $USERNAME, $PASSWORD ) = @_;

	# Database handle
	my $dbh;

	# Signify an error condition ( from the connection )
	my $error = undef;

	# Actually make the connection
	try {
		$dbh = DBI->connect(
			# The DSN we just set up
			$DSN,

			# Username
			$USERNAME,

			# Password
			$PASSWORD,

			# We set some configuration stuff here
			{
				# We do not want users seeing 'spam' on the commandline...
				'PrintError'	=>	0,

				# Automatically raise errors so we can catch them with try/catch
				'RaiseError'	=>	1,

				# Disable the DBI tracing
				'TraceLevel'	=>	0,
			}
		);

		# Check for undefined-ness
		if ( ! defined $dbh ) {
			die "Error Connecting to Database: $DBI::errstr";
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		# Declare it!
		output( make_error( 'DBI', $e ) );
		$error = 1;
	};

	# Catch errors!
	if ( $error ) {
		# QUIT
		return;
	}

	# Okay, now we listen for commands from our parent
	while ( sysread( STDIN, my $buffer = '', 1024 ) ) {
		# Feed the line into the filter
		my $data = $filter->get( [ $buffer ] );

		# INPUT STRUCTURE IS:
		# $d->{action}			= SCALAR	->	WHAT WE SHOULD DO
		# $d->{sql}				= SCALAR	->	THE ACTUAL SQL
		# $d->{placeholders}	= ARRAY		->	PLACEHOLDERS WE WILL USE
		# $d->{id}				= SCALAR	->	THE QUERY ID ( FOR PARENT TO KEEP TRACK OF WHAT IS WHAT )
		# $d->{primary_key}		= SCALAR 	->	PRIMARY KEY FOR A HASH OF HASHES

		# Process each data structure
		foreach my $input ( @$data ) {
			$input->{action} = lc($input->{action});
			# Now, we do the actual work depending on what kind of query it was
			if ( $input->{action} eq 'exit' ) {
				# Disconnect!
				$dbh->disconnect;
				return;
			} elsif ( $input->{action} eq 'do' ) {
				# Fire off the SQL and return success/failure + rows affected
				output( db_do( $dbh, $input ) );
			} elsif ( $input->{action} eq 'single' ) {
				# Return a single result
				output( db_single( $dbh, $input ) );
			} elsif ( $input->{action} eq 'quote' ) {
				output( db_quote( $dbh, $input ) );
			} elsif ( $input->{action} eq 'arrayhash' ) {
				# Get many results, then return them all at the same time in a array of hashes
				output( db_arrayhash( $dbh, $input ) );
			} elsif ( $input->{action} eq 'hashhash' ) {
				# Get many results, then return them all at the same time in a hash of hashes
				# on a primary key of course. the columns are returned in the cols key
				output( db_hashhash( $dbh, $input ) );
			} elsif ( $input->{action} eq 'hasharray' ) {
				# Get many results, then return them all at the same time in a hash of arrays
				# on a primary key of course. the columns are returned in the cols key
				output( db_hasharray( $dbh, $input ) );
			} elsif ( $input->{action} eq 'array' ) {
				# Get many results, then return them all at the same time in an array of comma seperated values
				output( db_array( $dbh, $input ) );
			} elsif ( $input->{action} eq 'hash' ) {
				# Get many results, then return them all at the same time in a hash keyed off the 
				# on a primary key of course
				output( db_hash( $dbh, $input ) );
			} elsif ( $input->{action} eq 'keyvalhash' ) {
				# Get many results, then return them all at the same time in a hash with
				# the first column being the key and the second being the value
				output( db_keyvalhash( $dbh, $input ) );
			} else {
				# Unrecognized action!
				output( make_error( $input->{id}, 'Unknown action sent' ) );
			}
		}
	}

	# Arrived here due to error in sysread/etc
	$dbh->disconnect;
}

# This subroutine makes a generic error structure
sub make_error {
	# Make the structure
	my $data = { id => shift };

	# Get the error, and stringify it in case of Error::Simple objects
	my $error = shift;

	if ( ref( $error ) && ref( $error ) eq 'Error::Simple' ) {
		$data->{error} = $error->text;
	} else {
		$data->{error} = $error;
	}

	# All done!
	return $data;
}

# This subroutine does a DB QUOTE
sub db_quote {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# The result
	my $quoted = undef;
	my $output = undef;

	# Quote it!
	try {
		$quoted = $dbh->quote( $data->{sql} );
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# Check for errors
	if ( ! defined $output ) {
		# Make output include the results
		$output = { result => $quoted, id => $data->{id} };
	}

	# All done!
	return $output;
}

# This subroutine runs a 'SELECT ... LIMIT 1' style query on the db
sub db_single {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = undef;

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = make_error( $data->{id}, "SINGLE is for SELECT queries only! ( $data->{sql} )" );
		return $output;
	}

# I don't like anything automaticly modifying my querys

#	# See if we have a 'LIMIT 1' in the end
#	if ( $data->{sql} =~ /LIMIT\s*\d*$/i ) {
#		# Make sure it is LIMIT 1
#		if ( $data->{sql} !~ /LIMIT\s*1$/i ) {
#			# Not consistent with this interface
#			$output = make_error( $data->{id}, "SINGLE -> SQL must not have a LIMIT clause ( $data->{sql} )" );
#		}
#	} else {
#		# Insert 'LIMIT 1' to the string to give the database engine some hints...
#		$data->{sql} .= ' LIMIT 1';
#	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{sql} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
		}

		# Actually do the query!
		try {
			# There are warnings when joining a NULL field, which is undef
			no warnings;
			if (exists($data->{seperator})) {
				$result = join($data->{seperator},$sth->fetchrow_array());
			} else {
				$result = $sth->fetchrow_array();
			}		
			use warnings;
		} catch Error with {
			die $sth->errstr;
		};
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# Check if we got any errors
	if ( ! defined $output ) {
		# Make output include the results
		$output = { result => $result, id => $data->{id} };
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
}

# This subroutine runs a 'DO' style query on the db
sub db_do {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $rows_affected = undef;

	# Check if this is a non-select statement
#	if ( $data->{sql} =~ /^SELECT/i ) {
#		# User is not a SQL whiz, obviously ;)
#		$output = make_error( $data->{id}, "DO is for non-SELECT queries only! ( $data->{sql} )" );
#		return $output;
#	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{sql} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$rows_affected = $sth->execute( $data->{placeholders} );
			} catch Error with {
				die $sth->errstr;
			};
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# If rows_affected is not undef, that means we were successful
	if ( defined $rows_affected && ! defined $output ) {
		# Make the data structure
		$output = { rows => $rows_affected, id => $data->{id} };
	} elsif ( ! defined $rows_affected && ! defined $output ) {
		# Internal error...
		die 'Internal Error in db_do';
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
}

sub db_arrayhash {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = [];

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = make_error( $data->{id}, "ARRAYHASH is for SELECT queries only! ( $data->{sql} )" );
		return $output;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{sql} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
		}

#		my $newdata;
#
#		# Bind the columns
#		try {
#			$sth->bind_columns( \( @$newdata{ @{ $sth->{'NAME_lc'} } } ) );
#		} catch Error with {
#			die $sth->errstr;
#		};

		# Actually do the query!
		try {
			my $rows = 0;
			while ( my $hash = $sth->fetchrow_hashref() ) {
				if (exists($data->{chunked}) && defined $output) {
					# chunk results ready to send
					output($output);
					$output = undef;
					$result = [];
					$rows = 0;
				}
				$rows++;
				# Copy the data, and push it into the array
				push( @{ $result }, { %{ $hash } } );
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$output = { id => $data->{id}, result => $result, chunked => $data->{chunked} };
				}
			}
			# in the case that our rows == chunk
			$output = undef;

		} catch Error with {
			die $sth->errstr;
		};

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# Check if we got any errors
	if ( ! defined $output ) {
		# Make output include the results
		$output = { id => $data->{id}, result => $result };
		if (exists($data->{chunked})) {
			$output->{last_chunk} = 1;
			$output->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
}

sub db_hashhash {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = {};

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = make_error( $data->{id}, "HASHHASH is for SELECT queries only! ( $data->{sql} )" );
		return $output;
	}

	my (@cols, %col);
	
	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{sql} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
		}

		# The result hash
		my $newdata = {};

		# Check the primary key
		my $foundprimary = 0;

		if ($data->{primary_key} =~ m/^\d+$/) {
			# primary_key can be a 1 based index
			if ($data->{primary_key} > $sth->{NUM_OF_FIELDS}) {
#				die "primary_key ($data->{primary_key}) is out of bounds (".$sth->{NUM_OF_FIELDS}.")";
				die "primary_key ($data->{primary_key}) is out of bounds";
			}
			
			$data->{primary_key} = $sth->{NAME}->[($data->{primary_key}-1)];
		}
		
		# Find the column names
		for my $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
			$col{$sth->{NAME}->[$i]} = $i;
			push(@cols, $sth->{NAME}->[$i]);
			$foundprimary = 1 if ($sth->{NAME}->[$i] eq $data->{primary_key});
		}
		
		unless ($foundprimary == 1) {
			die "primary key ($data->{primary_key}) not found";
		}
		
		# Actually do the query!
		try {
			my $rows = 0;
			while ( my @row = $sth->fetchrow_array() ) {
				if (exists($data->{chunked}) && defined $output) {
					# chunk results ready to send
					output($output);
					$output = undef;
					$result = {};
					$rows = 0;
				}
				$rows++;
				foreach my $c (@cols) {
					$result->{$row[$col{$data->{primary_key}}]}{$c} = $row[$col{$c}];
				}
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$output = { result => $result, id => $data->{id}, cols => [ @cols ], chunked => $data->{chunked}, primary_key => $data->{primary_key} };
				}
			}
			# in the case that our rows == chunk
			$output = undef;
			
		} catch Error with {
			die $sth->errstr;
		};

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# Check if we got any errors
	if ( ! defined $output ) {
		# Make output include the results
		$output = { id => $data->{id}, result => $result, cols => [ @cols ], primary_key => $data->{primary_key} };
		if (exists($data->{chunked})) {
			$output->{last_chunk} = 1;
			$output->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
}

sub db_hasharray {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = {};

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = make_error( $data->{id}, "HASHARRAY is for SELECT queries only! ( $data->{sql} )" );
		return $output;
	}

	my (@cols, %col);
	
	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{sql} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
		}

		# The result hash
		my $newdata = {};

		# Check the primary key
		my $foundprimary = 0;

		if ($data->{primary_key} =~ m/^\d+$/) {
			# primary_key can be a 1 based index
			if ($data->{primary_key} > $sth->{NUM_OF_FIELDS}) {
#				die "primary_key ($data->{primary_key}) is out of bounds (".$sth->{NUM_OF_FIELDS}.")";
				die "primary_key ($data->{primary_key}) is out of bounds";
			}
			
			$data->{primary_key} = $sth->{NAME}->[($data->{primary_key}-1)];
		}
		
		# Find the column names
		for my $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
			$col{$sth->{NAME}->[$i]} = $i;
			push(@cols, $sth->{NAME}->[$i]);
			$foundprimary = 1 if ($sth->{NAME}->[$i] eq $data->{primary_key});
		}
		
		unless ($foundprimary == 1) {
			die "primary key ($data->{primary_key}) not found";
		}
		
		# Actually do the query!
		try {
			my $rows = 0;
			while ( my @row = $sth->fetchrow_array() ) {
				if (exists($data->{chunked}) && defined $output) {
					# chunk results ready to send
					output($output);
					$output = undef;
					$result = {};
					$rows = 0;
				}
				$rows++;
				push(@{ $result->{$row[$col{$data->{primary_key}}]} }, @row);
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$output = { result => $result, id => $data->{id}, cols => [ @cols ], chunked => $data->{chunked}, primary_key => $data->{primary_key} };
				}
			}
			# in the case that our rows == chunk
			$output = undef;
			
		} catch Error with {
			die $sth->errstr;
		};

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# Check if we got any errors
	if ( ! defined $output ) {
		# Make output include the results
		$output = { result => $result, id => $data->{id}, cols => [ @cols ], primary_key => $data->{primary_key} };
		if (exists($data->{chunked})) {
			$output->{last_chunk} = 1;
			$output->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
}

sub db_array {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = [];

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = make_error( $data->{id}, "ARRAY is for SELECT queries only! ( $data->{sql} )" );
		return $output;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{sql} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
		}

		# The result hash
		my $newdata = {};
		
		# Actually do the query!
		try {
			my $rows = 0;	
			while ( my @row = $sth->fetchrow_array() ) {
				if (exists($data->{chunked}) && defined $output) {
					# chunk results ready to send
					output($output);
					$output = undef;
					$result = [];
					$rows = 0;
				}
				$rows++;
				# There are warnings when joining a NULL field, which is undef
				no warnings;
				if (exists($data->{seperator})) {
					push(@{$result},join($data->{seperator},@row));
				} else {
					push(@{$result},join(',',@row));
				}
				use warnings;
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$output = { result => $result, id => $data->{id}, chunked => $data->{chunked} };
				}
			}
			# in the case that our rows == chunk
			$output = undef;
			
		} catch Error with {
			die $!;
			#die $sth->errstr;
		};

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# Check if we got any errors
	if ( ! defined $output ) {
		# Make output include the results
		$output = { result => $result, id => $data->{id} };
		if (exists($data->{chunked})) {
			$output->{last_chunk} = 1;
			$output->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
}

sub db_hash {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = {};

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = make_error( $data->{id}, "HASH is for SELECT queries only! ( $data->{sql} )" );
		return $output;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{sql} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
		}

		# The result hash
		my $newdata = {};
		
		# Actually do the query!
		try {

			my @row = $sth->fetchrow_array();
			
			if (@row) {
				for my $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
					$result->{$sth->{NAME}->[$i]} = $row[$i];
				}
			}
			
		} catch Error with {
			die $sth->errstr;
		};

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# Check if we got any errors
	if ( ! defined $output ) {
		# Make output include the results
		$output = { result => $result, id => $data->{id} };
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
}

sub db_keyvalhash {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = {};

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = make_error( $data->{id}, "KEYVALHASH is for SELECT queries only! ( $data->{sql} )" );
		return $output;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{sql} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
		}

		# Actually do the query!
		try {
			my $rows = 0;
			while (my @row = $sth->fetchrow_array()) {
				if ($#row < 1) {
					die 'You need at least 2 columns selected for a keyvalhash query';
				}
				if (exists($data->{chunked}) && defined $output) {
					# chunk results ready to send
					output($output);
					$output = undef;
					$result = {};
					$rows = 0;
				}
				$rows++;
				$result->{$row[0]} = $row[1];
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$output = { result => $result, id => $data->{id}, chunked => $data->{chunked} };
				}
			}
			# in the case that our rows == chunk
			$output = undef;
			
		} catch Error with {
			die $sth->errstr;
		};

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		$output = make_error( $data->{id}, $e );
	};

	# Check if we got any errors
	if ( ! defined $output ) {
		# Make output include the results
		$output = { result => $result, id => $data->{id} };
		if (exists($data->{chunked})) {
			$output->{last_chunk} = 1;
			$output->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
}

# Prints any output to STDOUT
sub output {
	# Get the data
	my $data = shift;

	# Freeze it!
	my $output = $filter->put( [ $data ] );

	# Print it!
	print STDOUT @$output;
}

# End of module
1;


__END__

=head1 NAME

POE::Component::EasyDBI::SubProcess - Backend of POE::Component::EasyDBI

=head1 ABSTRACT

This module is responsible for implementing the guts of POE::Component::EasyDBI.
The fork and the connection to the DBI.

=head2 EXPORT

Nothing.

=head1 SEE ALSO

L<POE::Component::EasyDBI>

L<DBI>

L<POE>
L<POE::Wheel::Run>
L<POE::Filter::Reference>

L<POE::Component::DBIAgent>
L<POE::Component::LaDBI>
L<POE::Component::SimpleDBI>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 CREDITS

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003 by David Davis and Teknikill Software

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
