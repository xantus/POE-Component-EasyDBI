#use 5.008;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile(
    'NAME'			=> 'POE::Component::EasyDBI',
    'VERSION_FROM'	=> 'lib/POE/Component/EasyDBI.pm', # finds $VERSION
    'PREREQ_PM'		=> {
		'POE'		=>	'0.20',
		'DBI'		=>	'1.38',
		'Error'		=>	'0.15',
		'Carp'		=>	'0',
    },

    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
		(ABSTRACT_FROM	=> 'lib/POE/Component/EasyDBI.pm', # retrieve abstract from module
		 AUTHOR			=> 'David Davis <xantus@cpan.org>') : ()),
);
