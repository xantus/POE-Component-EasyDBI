requires 'perl', '5.00600';
requires 'strict';
requires 'warnings';
requires 'Carp';
requires 'POSIX';
requires 'POE', '0.3101';
requires 'DBI', '1.38';
requires 'Error', '0.15';

on configure => sub {
	requires 'Module::Build';
};

on test => sub {
	requires 'Test::More';
	requires 'Test::Requires', '0.08';
	recommends 'DBD::SQLite';
	recommends 'Time::Stopwatch';
};

on develop => sub {
	requires 'CPAN::Meta', '2.143240';
	requires 'DBD::SQLite';
	requires 'Time::Stopwatch';
};
