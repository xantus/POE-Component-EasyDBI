#!/usr/bin/perl

use lib qw(../blib ../lib);

use POE qw(Component::EasyDBI);

$|++;

die "setup a database and edit this file first\n";

# Set up the DBI
if (0) {
	# postgresql
	POE::Component::EasyDBI->new(
		alias		=> 'EasyDBI',
		dsn			=> 'DBI:Pg:dbname=template1',
		username	=> 'postgres',
		password	=> '',
		max_retries => -1,
		ping_timeout => 10,
		no_connect_failures => 1,
		reconnect_wait => 4,
		connect_error => [ 'test', 'connect_error' ],
	);
} else {
	# mysql
	POE::Component::EasyDBI->new(
		alias		=> 'EasyDBI',
		dsn			=> 'DBI:mysql:db=test;host=localhost',
		username	=> 'mysql',
		password	=> '',
		max_retries => -1,
		ping_timeout => 10,
		no_connect_failures => 1,
		reconnect_wait => 4,
		connect_error => [ 'test', 'connect_error' ],
	);

}

# Create our own session to communicate with EasyDBI
POE::Session->create(
	inline_states => {
		_start => sub {
			my $kernel = $_[KERNEL];
			$kernel->alias_set('test');
			
			$kernel->post( 'EasyDBI',
				do => {
					sql => 'DELETE FROM sessions',
					event => 'deleted_handler',
				}
			);
	
			$kernel->yield('insert');
		},
		insert => sub {
			my $kernel = $_[KERNEL];
			
			$kernel->post( 'EasyDBI',
				insert => {
					sql => 'INSERT INTO sessions (sessid,expiration,value) VALUES(?,?,?)',
					event => 'insert_handler',
					placeholders => [ $heap->{session}++, time(), 'testing!'  ],
				}
			);
			print ".";
			$kernel->delay_set('insert' => 2);
		},
		deleted_handler => \&deleted_handler,
		insert_handler	=> \&insert_handler,
		connect_error => sub {
			print "connect error $_[ARG0]->{error}\n";
		},
	},
);
	
$poe_kernel->run();

exit;

sub deleted_handler {
	my $i = $_[ARG0];
	if ($i->{error}) {
		die "$i->{error}";
	}
	# For DO calls, we receive the scalar value of rows affected
	# $_[ARG0] = {
	#	sql => The SQL you sent
	#	result	=> scalar value of rows affected
	#	placeholders => The placeholders
	#	action => 'do'
	#	error => Error occurred, check this first
	# }
	print "deleted $i->{result} rows\n";
}

sub insert_handler {
	my $i = $_[ARG0];
	if ($i->{error}) {
		print "$i->{error}\n";
	}
	print ":";
}

