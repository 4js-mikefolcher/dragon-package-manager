#!/usr/bin/perl -w

use strict;

use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use XML::Simple;
use HTTP::Request;
use LWP::UserAgent;
use IO::Socket::SSL;
use Data::Dumper;
use Getopt::Std;
use File::Copy;

my $default_root_url = "https://fourjsusa.jfrog.io/artifactory/genero-tools";

sub get_package_zip_file {

   my $l_package_name = shift;
   my $l_zip_name = "package.zip";
   if ($l_package_name =~ /\.([A-z0-9_-]+)$/) {
      $l_zip_name = $1 . ".zip";
   }
   return $l_zip_name;

}

sub get_package_dir_path {

   my $l_package_name = shift;
   my $l_dir_path = $l_package_name;
   $l_dir_path =~ s/\./\//g;
   return $l_dir_path;

}

sub get_tmp_dir {

    my $l_tmp_dir = ".dragon";
    if (! -d $l_tmp_dir) {
       mkdir $l_tmp_dir;
    }
    return $l_tmp_dir;
}

sub get_user_dir {

   my $l_home = $ENV{"HOME"};
   if (! -d $l_home) {
      $l_home = $ENV{"USERPROFILE"};
      die "Could not determine home directory " unless (-d $l_home);
   }
   my $l_user_tmp = $l_home . "/.dragon";
   if (! -d $l_user_tmp) {
      mkdir($l_user_tmp, 0700);
   }
   return $l_user_tmp;

}

sub create_package {

   my $l_package_name = shift;
   my $l_directory = shift;
   my $l_zip_name = get_package_zip_file($l_package_name);
   my $l_package_path = get_package_dir_path($l_package_name);
   my $l_dir_path = "";

   if (defined $l_directory) {
      $l_dir_path = "${l_directory}/${l_package_path}";
   } else {
      $l_dir_path = $l_package_path;
   }

   if (! -d $l_dir_path) {
      die "Directory $l_dir_path does not exist!\n";
   }

   my %l_package_info = read_package_xml($l_dir_path);

   my $l_zip = Archive::Zip->new();
   $l_zip->addTree($l_dir_path, $l_package_path);
   $l_zip->writeToFileNamed($l_zip_name);

   my $l_basename = $l_zip_name;
   if ($l_basename =~ /\/([A-z0-9._-]+)$/) {
      $l_basename = $1;
   }

   print "Package zip created: $l_zip_name \n";
   print "Package name: $l_package_info{'package'} \n";
   print "Genero Version: $l_package_info{'genero-version'} \n";
   print "Version: $l_package_info{'version'} \n";
   print "Package URL path should be: " .
         "g" . $l_package_info{'genero-version'} . "/" .
         "v" . $l_package_info{'version'} . "/" .
         $l_basename . "\n";

   return $l_zip_name;

}

sub fetch_uri {

    my $l_baseuri = shift;
    my $l_package_name = shift;
    my $l_genero_version = shift;
    my $l_package_version = shift;

    my $l_package_file = get_package_zip_file($l_package_name);
    my $l_file_path = $l_baseuri;
    $l_file_path .= "/g${l_genero_version}/v${l_package_version}/${l_package_file}";

    my $l_tmp_dir = get_tmp_dir();
    my $l_tmp_package = "${l_tmp_dir}/$l_package_file";

    print "Copying $l_file_path to $l_tmp_package \n";
    copy($l_file_path, $l_tmp_package);
    return $l_tmp_package;

}

sub fetch_package {

    my $l_baseurl = shift;
    my $l_package_name = shift;
    my $l_genero_version = shift;
    my $l_package_version = shift;
    my @l_headers = @_;

    if ($l_baseurl =~ /^file[:]/i) {
       return fetch_uri($l_baseurl, $l_package_name, $l_genero_version, $l_package_version);
    }

    my $l_package_file = get_package_zip_file($l_package_name);

    my $ua = LWP::UserAgent->new;
    $ua->agent("Dragon/1.0 ");
    $ua->ssl_opts(
       SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
       verify_hostname => 0
    );

    my $url = "${l_baseurl}/g${l_genero_version}/v${l_package_version}/${l_package_file}";
    my $req = HTTP::Request->new(GET => $url);
    for my $l_header (@l_headers) {
       my @l_pieces = split(/:/, $l_header);
       if (@l_pieces > 1) {
          $req->header($l_pieces[0] => $l_pieces[1]);
       }
    }

    my $content = "";
    my $res = $ua->request($req);
    if ($res->is_success) {
       $content = $res->content;
    } else {
       print "HTTP GET error code: " . $res->code . "\n";
       print "HTTP GET error message: " . $res->message . "\n";
       die "Error: $res->status_line, \n";
    }

    die "Couldn't get from ${url} !" unless defined $content;

    my $l_tmp_dir = get_tmp_dir();

    my $l_tmp_package = "${l_tmp_dir}/$l_package_file";

    open OUTPUTFILE, "> $l_tmp_package" || die "Cannot create $l_tmp_package for writing: $! \n";
    print OUTPUTFILE $content;
    close OUTPUTFILE;

    return $l_tmp_package;

}

sub unzip_package {

   my $l_zipfile = shift;
   my $l_target_dir = shift;

   my $l_zip = Archive::Zip->new();
   my $l_status = $l_zip->read($l_zipfile);
   my @l_members = $l_zip->memberNames();
   die "Read of $l_zip failed\n" if $l_status != AZ_OK;

   foreach my $l_member (@l_members) {
      print "Extracting $l_member to ${l_target_dir}/${l_member} \n";
      $l_zip->extractMember($l_member, "${l_target_dir}/${l_member}");
   }

}

sub do_install {

   my ($l_repo_name, $l_package, $l_version, $l_genero) = @_;
   my $l_repo_info = read_repo_file($l_repo_name);

   #Get the repo url and HTTP headers
   my $l_url = $l_repo_info->{$l_repo_name}->{url};
   my @l_headers = ();
   if (defined $l_repo_info->{$l_repo_name}->{header}) {
      @l_headers = @{$l_repo_info->{$l_repo_name}->{header}};
   }

   #Fetch the zip file
   my $l_zip_file = fetch_package($l_url, $l_package, $l_genero, $l_version, @l_headers);

   #Unpack the zip file
   my $l_pack_dir = "bdl_packages";
   unzip_package($l_zip_file, $l_pack_dir);

}

sub read_package_xml {

   my $l_package_path = shift;
   my $l_package_file = $l_package_path . "/package.xml";
   if (! -f $l_package_file) {
      die "File $l_package_file does not exist!\n";
   }

   my $ref = XMLin($l_package_file);
   #print Dumper($ref);
   my %l_hash = ();
   $l_hash{"package"} = $ref->{"name"};
   $l_hash{"genero-version"} = $ref->{"genero-version"};
   $l_hash{"version"} = $ref->{"version"};

   return %l_hash;

}

sub init_dragon_xml {

   my $l_xml_file = "dragon.xml";
   if (! -f $l_xml_file) {
      my $l_ref = {};
      open my $l_xml_handler, '>:encoding(iso-8859-1)', $l_xml_file or die "open($l_xml_file): $!";
      XMLout($l_ref, RootName => 'packages', OutputFile => $l_xml_handler);
      close $l_xml_handler;
   }

}

sub read_dragon_xml {

   my $l_dragon_xml = "dragon.xml";
   if (! -f $l_dragon_xml) {
      die "File $l_dragon_xml does not exist!\n";
   }

   my $l_ref = XMLin($l_dragon_xml, ForceArray => ['package', 'name'], NoAttr => 1);
   return $l_ref;

}

sub write_dragon_xml {

   my ($l_repo_name, $l_package, $l_version, $l_genero) = @_;

   my $l_dragon_xml = "dragon.xml";

   my $l_xmlref = get_install_list();

   #print "xmlref after call to get_install_list()\n";
   #print Dumper($l_xmlref);

   my $l_found = 0;
   my $l_count = 0;

   foreach my $l_packref (@{$l_xmlref->{packages}->{package}}) {
      my $l_name = $l_packref->{name};
      if ($l_name eq $l_package) {
         $l_found = 1;
         $l_xmlref->{packages}->{package}[$l_count]->{name} = $l_package;
         $l_xmlref->{packages}->{package}[$l_count]->{version} = $l_version;
         $l_xmlref->{packages}->{package}[$l_count]->{repo} = $l_repo_name;
         $l_xmlref->{packages}->{package}[$l_count]->{genero} = $l_genero;
         last;
      }
      $l_count++;
   }

   #print "xmlref after call to foreach\n";
   #print "Count: $l_count and found: $l_found \n";
   #print Dumper($l_xmlref);

   if ($l_found == 0) {
        $l_xmlref->{packages}->{package}[$l_count]->{name} = $l_package;
        $l_xmlref->{packages}->{package}[$l_count]->{version} = $l_version;
        $l_xmlref->{packages}->{package}[$l_count]->{repo} = $l_repo_name;
        $l_xmlref->{packages}->{package}[$l_count]->{genero} = $l_genero;
   }

   #print "xmlref after found logic \n";
   #print Dumper($l_xmlref);
   open my $l_xml_handler, '>:encoding(iso-8859-1)', $l_dragon_xml or die "open($l_dragon_xml): $!";
   XMLout($l_xmlref, KeepRoot => 1, NoAttr => 1, OutputFile => $l_xml_handler);

   print "Package $l_package has been added to your dragon.xml file\n";

}

sub get_install_list {

   my $l_dragon_xml = "dragon.xml";

   my $l_ref = read_dragon_xml();

   #print "Reading dragon.xml values\n";
   #print Dumper($l_ref);

   my $l_xmlref = {};
   my $l_count = 0;

   $l_xmlref->{packages}->{package} = ();

   foreach my $l_packref (@{$l_ref->{package}}) {

      my $l_name = $l_packref->{name}[0];
      $l_xmlref->{packages}->{package}[$l_count]->{name} = $l_name;
      $l_xmlref->{packages}->{package}[$l_count]->{version} = $l_packref->{version};
      $l_xmlref->{packages}->{package}[$l_count]->{repo} = $l_packref->{repo};
      $l_xmlref->{packages}->{package}[$l_count]->{genero} = $l_packref->{genero};
      $l_count++;
      print "Adding $l_name package\n";

   }

   #print "After xmlref translation\n";
   #print Dumper($l_xmlref);

   return $l_xmlref;

}

sub update_package {

   my ($l_repo_name, $l_package, $l_version, $l_genero) = @_;

   do_install($l_repo_name, $l_package, $l_version, $l_genero);
   print "Package $l_package has been updated\n";

}

sub update_single_package {

   my $l_package = shift;
   my $l_xmlref = get_install_list();

   my $l_found = 0;

   foreach my $l_packref (@{$l_xmlref->{packages}->{package}}) {
      my $l_name = $l_packref->{name};
      if ($l_name eq $l_package) {
         my $l_repo = $l_packref->{repo};
         my $l_version = $l_packref->{version};
         my $l_genero = $l_packref->{genero};
         update_package($l_repo, $l_name, $l_version, $l_genero);

         $l_found = 1;
         last;
      }
   }

   print "Package $l_package was not found in your dragon.xml file\n" unless $l_found == 1;

}

sub update_all_packages {

   my $l_xmlref = get_install_list();

   foreach my $l_packref (@{$l_xmlref->{packages}->{package}}) {
      my $l_name = $l_packref->{name};
      my $l_repo = $l_packref->{repo};
      my $l_version = $l_packref->{version};
      my $l_genero = $l_packref->{genero};
      update_package($l_repo, $l_name, $l_version, $l_genero);
   }

}

sub write_repo_file {
   my $l_name = shift;
   my $l_url = shift;
   my @l_headers = @_;

   my $l_filepath = get_user_dir() . "/" . $l_name . ".xml";
   open my $l_repo_handler, '>:encoding(iso-8859-1)', $l_filepath or die "open($l_filepath): $!";

   my $l_hashref = {};
   $l_hashref->{$l_name}->{name} = $l_name;
   $l_hashref->{$l_name}->{url} = $l_url;
   @{$l_hashref->{$l_name}->{header}} = @l_headers;
   XMLout($l_hashref, RootName => 'repo', OutputFile => $l_repo_handler);
   close $l_repo_handler;
   print "Repo file $l_filepath created \n";

}

sub read_repo_file {

   my $l_name = shift;
   my $l_filepath = get_user_dir() . "/" . $l_name . ".xml";

   if (! -f $l_filepath) {
      die "Repo file $l_filepath does not exist!\n";
   }

   my $ref = XMLin($l_filepath, ForceArray => qr/header$/);
   #print Dumper($ref->{$l_name});

   return $ref;

}

sub get_repo_list {

   my $l_repo_dir = get_user_dir();
   my %repos = ();
   opendir(my $dh, $l_repo_dir) || die "Can't open $l_repo_dir: $!";
   while (readdir $dh) {
      my $filename = $_;
      if ($filename =~ /(.*)\.xml/i) {
         my $repo = $1;
         $repos{$repo} = 0 unless exists($repos{$repo});
      } elsif ($filename =~ /(.*)\.default/i) {
         $repos{$1} = 1;
      }
   }
   closedir($dh);
   return %repos;

}

sub get_default_repo {

   my %l_repo_list = get_repo_list();

   for my $l_repo (keys %l_repo_list) {
      if ($l_repo_list{$l_repo} == 1) {
         return $l_repo;
      }
   }

   return "";

}

sub make_repo_default {

   my $l_name = shift;
   my $l_repo_default = get_user_dir() . "/" . $l_name . ".default";

   my %repos = get_repo_list(); 
   foreach my $key (keys(%repos)) {
      if ($repos{$key} == 1) {
         my $l_old_default = get_user_dir() . "." . $key . ".default";
         unlink $l_old_default || die "Could not remove file $l_old_default \n";
         last;
      }
   }

   open DEFAULTFILE, "> $l_repo_default" || die "Cannot create $l_repo_default for writing: $! \n";
   print DEFAULTFILE $l_name . "\n";
   close DEFAULTFILE;

}

sub remove_repo {

   my $l_name = shift;
   my $l_repo_xml = get_user_dir() . "/" . $l_name . ".xml";
   my $l_repo_default = get_user_dir() . "/" . $l_name . ".default";

   if (-f $l_repo_default) {
      unlink $l_repo_default;
   }

   if (-f $l_repo_xml) {
      unlink $l_repo_xml;
      print "Repo $l_name has been removed\n";
   } else {
      print "Repo $l_name does not exist\n";
   }

}

sub run_tests {

   #Test package creation
   my $zip_file = create_package("com.fourjs.RESTLibrary");
   print "Zip file $zip_file created!\n";
   if (-f $zip_file) {
      print "File ( $zip_file ) exists! \n";
      unlink($zip_file) || die "Could not delete file $zip_file !\n";
   }

   #Test package fetch
   $zip_file = fetch_package("4.01", "1.0", "com.fourjs.RESTLibrary");
   print "Zip file $zip_file created!\n";
   if (-f $zip_file) {
      print "File ( $zip_file ) exists! \n";
      unlink($zip_file) || die "Could not delete file $zip_file !\n";
   }

}

sub create_block {

   # declare the perl command line flags/options we want to allow
   my %options=();
   getopts("hp:d:", \%options);

   my $l_package_name = "";
   my $l_directory = "";

   #if the help flag is set, show the usage and return
   if (defined $options{h}) {
      create_usage();
      return;
   }

   #The package flag is required, get the package name
   if (defined $options{p}) {
      $l_package_name = $options{p};
   } else {
      print "Error: A package was not specified\n";
      create_usage();
      return;
   }

   if (defined $options{d}) {
      $l_directory = $options{d};
   }

   create_package($l_package_name, $l_directory);

}

sub create_usage {

   print "Usage: dragon.pl create -p [package] -d [directory] \n";
   print "Description: Create a Genero package\n";
   print "\tOption\t\tDescription\n";
   print "\t------\t\t-----------\n";
   print "\t-p\t\t(Required) Name of the package, example: com.fourjs.Example\n";
   print "\t-d\t\t(Optional) Directory path where the root package directory exists, example 'build'\n";

}

sub install_block {

   # declare the perl command line flags/options we want to allow
   my %options=();
   getopts("hp:r:v:g:", \%options);

   #if the help flag is set, show the usage and return
   if (defined $options{h}) {
      install_usage();
      return;
   }

   my $l_repo = "";
   my $l_repo_info;
   if (defined $options{r}) {
      $l_repo = $options{r};
   } else {
      $l_repo = get_default_repo();
   }

   if (defined $l_repo) {
      $l_repo_info = read_repo_file($l_repo);
   } else {
      print "Package repository not defined\n";
      install_usage();
   }

   my $l_package = "";
   if (defined $options{p}) {
      $l_package = $options{p};
   } else {
      print "Package is missing or invalid\n";
      install_usage();
   }

   my $l_version = "latest";
   if (defined $options{v}) {
      $l_version = $options{v};
   }

   my $l_genero = "";
   if (defined $options{g}) {
      $l_genero = $options{g};
   } else {
      print "Genero version has not been specified\n";
      install_usage();
   }

   #Get the repo url and HTTP headers
   my $l_url = $l_repo_info->{$l_repo}->{url};
   my @l_headers = ();
   if (defined $l_repo_info->{$l_repo}->{header}) {
      @l_headers = @{$l_repo_info->{$l_repo}->{header}};
   }

   #Fetch the zip file
   my $l_zip_file = fetch_package($l_url, $l_package, $l_genero, $l_version, @l_headers);

   #Unpack the zip file
   my $l_pack_dir = "bdl_packages";
   unzip_package($l_zip_file, $l_pack_dir);

   my $l_package_path = $l_pack_dir . "/" . get_package_dir_path($l_package);
   my %l_pack_info = read_package_xml($l_package_path);

   init_dragon_xml();
   write_dragon_xml($l_repo, $l_package, $l_version, $l_genero);

}

sub install_usage {

   print "Usage: dragon.pl install -p [package] -r [repo] -v [version] -g [genero-version] \n";
   print "Description: Install a new package in the current working directory\n";
   print "\tOption\t\tDescription\n";
   print "\t------\t\t-----------\n";
   print "\t-p\t\t(Required) Name of the package, example: com.fourjs.Example\n";
   print "\t-r\t\t(Optional) Use a named repo defined with dragon.pl repo, will use the default if not specified\n";
   print "\t-v\t\t(Optional) Install a specific version of the package, will install the latest if not specified\n";
   print "\t-g\t\t(Required) Install a version compatible with a specific Genero version\n";

}

sub update_block {

   # declare the perl command line flags/options we want to allow
   my %options=();
   getopts("hp:", \%options);

   #if the help flag is set, show the usage and return
   if (defined $options{h}) {
      update_usage();
      return;
   }

   if (defined $options{p}) {
      my $l_package = $options{p};
      update_single_package($l_package);
   } else {
      update_all_packages();
   }

}

sub update_usage {

   print "Usage: dragon.pl update -p [package] \n";
   print "Description: Updates packages based on what is in dragon.xml, you can alternatively update just one package\n";
   print "\tOption\t\tDescription\n";
   print "\t------\t\t-----------\n";
   print "\t-p\t\t(Optional) Name of the package, example: com.fourjs.Example\n";

}

sub remove_block {

}

sub remove_usage {

}

sub repo_block {

   # declare the perl command line flags/options we want to allow
   my %options=();
   getopts("hla:d:r:k:u:", \%options);

   #if the help flag is set, show the usage and return
   if (defined $options{h}) {
      repo_usage();
      return;
   }

   #list all the available repos
   if (defined $options{l}) {
      my %repos = get_repo_list();
      print "dragon.pl - Artifact Repositories defined\n";
      foreach my $key (keys(%repos)) {
         if ($repos{$key} == 1) {
            print "\tRepository Name: $key (default)\n";
         } else {
            print "\tRepository Name: $key\n";
         }
         my $ref = read_repo_file($key);
         print "\tRepository URL: " . $ref->{$key}->{url} . "\n\n";
      }
      return;
   }

   #add a new repo
   if (defined $options{a}) {
      my $l_name = $options{a};
      my $l_url = $options{u};
      my @l_keys = ();
      @l_keys = split(/,/, $options{k}) if defined $options{k};
      write_repo_file($l_name, $l_url, @l_keys);
      return;
   }

   #Set a repo as default 
   if (defined $options{d}) {
      my $l_name = $options{d};
      my %repos = get_repo_list();
      if (exists($repos{$l_name})) {
         make_repo_default($l_name);
      } else {
         print "No repo named $l_name has been defined!\n";
      }
   }

   #Remove the specified repo
   if (defined $options{r}) {
      my $repo_name = $options{r};
      remove_repo($repo_name);
   }

}

sub repo_usage {

   print "Usage: dragon.pl repo -l -r [repo name] -a [repo name] -d [repo name] -k [header key info] -u [repo root URL]\n";
   print "Description: Create a Genero package\n";
   print "\tOption\t\tDescription\n";
   print "\t------\t\t-----------\n";
   print "\t-l\t\tList all the repos defined by the user\n";
   print "\t-r\t\tRemove a repo defined for the user\n";
   print "\t-a\t\tAdd a new repo for Genero packages\n";
   print "\t-d\t\tSet the specified repo as the default for Genero packages\n";
   print "\t-k\t\tSpecify HTTP request header information, use a comma to separate if there are multiple,\n";
   print "\t\t\t  example: \"X-JFrog-Art-Api: XYZe1kWXuIqV833907QwXzfGiUUdYGuPXnTLFv59EhvRNh6JjMPnUqNq38W9MMFsinTYKgSAt\"\n";
   print "\t-u\t\tSpecify HTTP request root URL for the package repo,\n";
   print "\t\t\t  example: https://fourjsusa.jfrog.io/artifactory/genero-tools\n";

}

sub dragon_usage {

   print "Usage: dragon.pl [create|install|update|remove|repo] [options]\n";
   print "Description: The dragon.pl Genero package manager allows users to manage the package dependencies\n\n";

   create_usage();
   print "\n";

   repo_usage();
   print "\n";

   install_usage();
   print "\n";

   update_usage();
   print "\n";

}

my $cmd = shift;
dragon_usage() && exit 1 unless defined $cmd;

if ($cmd eq "create") {
   create_block();
} elsif ($cmd eq "install") {
   install_block();
} elsif ($cmd eq "update") {
   update_block();
} elsif ($cmd eq "remove") {
   remove_block();
} elsif ($cmd eq "repo") {
   repo_block();
} else {
   dragon_usage();
   exit 1;
}

