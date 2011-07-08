use inc::Module::Install;

# Metadata
name			'POE-Component-Client-eris';
perl_version 	'5.008';
author_from		'lib/POE/Component/Client/eris.pm';
version_from	'lib/POE/Component/Client/eris.pm';

# Other stuff
requires		'POE'		 					=> 0;
requires		'POE::Component::Client::TCP'	=> 0;
requires		'Parse::Syslog::Line'			=> 0;
test_requires	'Test::More'					=> 0;

install_script 'scripts/eris-syslog-ng.pl';

WriteAll;
