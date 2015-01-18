use 5.006;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

my $eumm_version = eval $ExtUtils::MakeMaker::VERSION;

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

    ABSTRACT_FROM => 'lib/POE/Component/EasyDBI.pm', # retrieve abstract from module
    AUTHOR  => 'David Davis <xantus@cpan.org>',

    ## perl 5.8.9
    (
        LICENSE => 'perl_5',
    )x!! ($eumm_version >= 6.31),

    ## perl 5.10.1
    (
        MIN_PERL_VERSION =>'5.006000',
    )x!! ($eumm_version >= 6.48),

    (
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
            },
            prereqs => {
                test => {
                    # This is redundant with TEST_REQUIRES, but will
                    # also work with EUMM 6.46 to 6.63
                    requires => {
                        'Test::More' => 0,
                        'Test::Requires' => '0.08',
                    },
                    recommends => {
                        'DBD::AnyData' => 0,
                        'DBD::SQLite' => 0,
                        'Time::Stopwatch' => 0,
                    },
                },
                develop => {
                    requires => {
                        'CPAN::Meta' => '2.143240', # latest
                        # Contributors must run the whole testsuite
                        'DBD::AnyData' => 0,
                        'DBD::SQLite' => 0,
                        'Time::Stopwatch' => 0,
                    },
                },
            },
        },
    )x!! ($eumm_version >= 6.46),

    ## perl 5.18
    (
        TEST_REQUIRES => {
            'Test::More' => 0,
            'Test::Requires' => '0.08',
        },
    )x!! ($eumm_version >= 6.64),
);
