#use 5.008;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile(
    'NAME'         => 'POE::Component::EasyDBI',
    'VERSION_FROM' => 'lib/POE/Component/EasyDBI.pm', # finds $VERSION
    'PREREQ_PM'    => {
        'POE'          => ( ( $^O eq 'MSWin32' ) ? '0.3101' : '0.20' ),
        'DBI'          => '1.38',
        'Error'        => '0.15',
        'Carp'         => 0,
        'Params::Util' => 0,
        'Scalar::Util' => 0,
        #'DBD::AnyData' => 0,
    },
    'dist' => {
        'SUFFIX'       => ".gz",
        'DIST_DEFAULT' => 'all tardist',
        'COMPRESS'     => "gzip -9vf",
    },

    (
        $] >= 5.10.1
        ? ## Add these new keywords supported since 5.10.1
          (
            ABSTRACT_FROM => 'lib/POE/Component/EasyDBI.pm', # retrieve abstract from module
            LICENSE => 'perl_5',
            AUTHOR  => 'David Davis <xantus@cpan.org>',
            MIN_PERL_VERSION =>'5.006000',
            META_MERGE    => {
                "meta-spec" => { version => 2 },
                resources   => {
                    license => ['http://dev.perl.org/licenses/'],
                    bugtracker => {
                        web => 'https://rt.cpan.org/Public/Dist/Display.html?Name=POE-Component-EasyDBI',
                    },
                    repository => {
                        type => 'git',
                        url  => 'https://github.com/gps4net/POE-Component-EasyDBI.git',
                        web  => 'https://github.com/gps4net/POE-Component-EasyDBI'
                    }
                }
            },
          )
        : $] >= 5.005
        ? ## Add these new keywords supported since 5.005
          (
            ABSTRACT_FROM => 'lib/POE/Component/EasyDBI.pm', # retrieve abstract from module
            LICENSE => 'perl_5',
            AUTHOR  => 'David Davis <xantus@cpan.org>'
          )
        : ()
    ),
);
