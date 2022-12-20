# dragon-package-manager
Package Manager for Genero

## The Dragon Package Manager (dragon.pl) is package manage for Genero
The Dragon Package Manager allows you to create, install, and update
packages in you project.  It is written in Perl and is a single monolithic
file with a few dependencies.

## Prerequisites
Perl must be installed.
In addition to Perl, the following Perl libraries must be installed:
- Archive::Zip
- XML::Simple
- LWP::UserAgent
- IO::Socket::SSL
- Data::Dumper
- Getopt::Std

You can use cpan (the Perl package manager) to install these libraries. For
example: 
`cpan Archive::Zip`

## Usage
Once dragon.pl is downloaded and installed, it can be used to create and install
Genero packages.  It has 4 main commands that are currently supported.
- create: Allows you to create a new Dragon package for distribution
- install: Install a new package
- update: Update existing packages based on the dragon.xml file
- repo: Add or Remove a distribution repository for installing packages


## TODO Items
The following items are planned but have not been implemented yet.
- Remove command to remove an installed package
- Allow packages to be loaded from disk, currently the packages must be available via HTTP
- Add debug command to display messages
- Code cleanup
