# POE::Component::EasyDBI

This module simplifies DBI usage in POE's multitasking world.

This module is easy to use, you'll have DBI calls in your POE program
up and running in no time.

# INSTALLATION

To install this module type the following:

   perl Makefile.PL
   make
   make test
   make install

# DEPENDENCIES

This module requires these other modules and libraries:

	POE > 0.20
		POE::Session
		POE::Wheel::Run
		POE::Filter::Reference
		POE::Filter::Line

	DBI > 1.30

	Carp

	Error > 0.15

Optional:

	SQLite
		(for tests)

# AUTHOR

David Davis <xantus@cpan.org>

# CREDITS

- Apocalypse <apocal@cpan.org>
- Chris Williams <chris@bingosnet.co.uk>
- Andy Grundman <andy@hybridized.org>
- Stephan Jauernick <stephan@stejau.de>

# COPYRIGHT AND LICENCE

Copyright 2003-2006 by David Davis and Teknikill Software

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.
