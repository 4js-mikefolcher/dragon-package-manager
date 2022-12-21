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

my $debug_mode = 0;

sub println {

   foreach my $l_line (@_) {
      print $l_line . "\n";
   }

}

sub debug_print {

   println(@_) if ($debug_mode > 0);

}

sub get_package_zip_file {

   my $l_package_name = shift;
   my $l_zip_name = "package.zip";
   if ($l_package_name =~ /\.([A-z0-9_-]+)$/) {
      $l_zip_name = $1 . ".zip";
   }
   debug_print("get_package_name returning $l_zip_name");
   return $l_zip_name;

}

sub get_package_dir_path {

   my $l_package_name = shift;
   my $l_dir_path = $l_package_name;
   $l_dir_path =~ s/\./\//g;
   debug_print("get_package_dir_path returning $l_dir_path");
   return $l_dir_path;

}

sub get_tmp_dir {

    my $l_tmp_dir = ".dragon";
    if (! -d $l_tmp_dir) {
       debug_print("making dragon work directory $l_tmp_dir");
       mkdir $l_tmp_dir;
    }
    debug_print("get_tmp_dir returning $l_tmp_dir");
    return $l_tmp_dir;
}

sub get_user_dir {

   my $l_home = $ENV{"HOME"};
   if (! -d $l_home) {
      $l_home = $ENV{"USERPROFILE"};
      die "Could not determine home directory " unless (-d $l_home);
   }
   debug_print("determined user home directory is $l_home");
   my $l_user_tmp = $l_home . "/.dragon";
   if (! -d $l_user_tmp) {
      debug_print("making dragon config directory $l_user_tmp");
      mkdir($l_user_tmp, 0700);
   }
   debug_print("get_user_dir returning $l_user_tmp");
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
   debug_print("Using package path of $l_dir_path");

   if (! -d $l_dir_path) {
      die "Directory $l_dir_path does not exist!\n";
   }

   my %l_package_info = read_package_xml($l_dir_path);

   my $l_zip = Archive::Zip->new();
   $l_zip->addTree($l_dir_path, $l_package_path);
   $l_zip->writeToFileNamed($l_zip_name);

   my $l_basename = $l_zip_name;
   if ($l_basename =~ /\/([A-z0-9._-]+)$/) {
      debug_print("Setting package basename to $l_basename");
      $l_basename = $1;
   }

   println("Package zip created: $l_zip_name");
   println("Package name: $l_package_info{'package'}");
   println("Genero Version: $l_package_info{'genero-version'}");
   println("Version: $l_package_info{'version'}");
   println("Package URL path should be: " .
         "g" . $l_package_info{'genero-version'} . "/" .
         "v" . $l_package_info{'version'} . "/" .
         $l_basename);

   debug_print("create_package returning $l_zip_name");
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
    debug_print("Using URI file path $l_file_path to install/update package");

    my $l_tmp_dir = get_tmp_dir();
    my $l_tmp_package = "${l_tmp_dir}/$l_package_file";

    println("Copying $l_file_path to $l_tmp_package");
    copy($l_file_path, $l_tmp_package);

    debug_print("fetch_uri returning $l_tmp_package");
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
       println("HTTP GET error code: " . $res->code);
       println("HTTP GET error message: " . $res->message);
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
      println("Extracting $l_member to ${l_target_dir}/${l_member}");
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

   debug_print("Reading file $l_package_file");
   my $ref = XMLin($l_package_file);
   debug_print(Dumper($ref));
   my %l_hash = ();
   $l_hash{"package"} = $ref->{"name"};
   $l_hash{"genero-version"} = $ref->{"genero-version"};
   $l_hash{"version"} = $ref->{"version"};

   debug_print("read_package_xml returning " . Dumper(%l_hash));
   return %l_hash;

}

sub init_dragon_xml {

   my $l_xml_file = "dragon.xml";
   if (! -f $l_xml_file) {
      my $l_ref = {};
      open my $l_xml_handler, '>:encoding(iso-8859-1)', $l_xml_file or die "open($l_xml_file): $!";
      XMLout($l_ref, RootName => 'packages', OutputFile => $l_xml_handler);
      close $l_xml_handler;
      debug_print("init_dragon_xml created an empty dragon.xml file");
   }

}

sub read_dragon_xml {

   my $l_dragon_xml = "dragon.xml";
   if (! -f $l_dragon_xml) {
      die "File $l_dragon_xml does not exist!\n";
   }

   my $l_ref = XMLin($l_dragon_xml, ForceArray => ['package', 'name'], NoAttr => 1);

   debug_print("read_dragon_xml returning " . Dumper($l_ref));
   return $l_ref;

}

sub write_dragon_xml {

   my ($l_repo_name, $l_package, $l_version, $l_genero) = @_;

   my $l_dragon_xml = "dragon.xml";

   my $l_xmlref = get_install_list();

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

   debug_print("Count: $l_count and found: $l_found for writing to $l_dragon_xml");
   debug_print(Dumper($l_xmlref));

   if ($l_found == 0) {
        $l_xmlref->{packages}->{package}[$l_count]->{name} = $l_package;
        $l_xmlref->{packages}->{package}[$l_count]->{version} = $l_version;
        $l_xmlref->{packages}->{package}[$l_count]->{repo} = $l_repo_name;
        $l_xmlref->{packages}->{package}[$l_count]->{genero} = $l_genero;
        debug_print("Package $l_package added to the $l_dragon_xml");
   }

   open my $l_xml_handler, '>:encoding(iso-8859-1)', $l_dragon_xml or die "open($l_dragon_xml): $!";
   XMLout($l_xmlref, KeepRoot => 1, NoAttr => 1, OutputFile => $l_xml_handler);

   println("Package $l_package has been added to your dragon.xml file");

}

sub get_install_list {

   my $l_dragon_xml = "dragon.xml";

   my $l_ref = read_dragon_xml();

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
      println("Adding $l_name package");

   }

   debug_print("get_install_list returning " . Dumper($l_xmlref));
   return $l_xmlref;

}

sub update_package {

   my ($l_repo_name, $l_package, $l_version, $l_genero) = @_;

   do_install($l_repo_name, $l_package, $l_version, $l_genero);
   println("Package $l_package has been updated");

}

sub update_single_package {

   my $l_package = shift;
   my $l_xmlref = get_install_list();

   my $l_found = 0;

   foreach my $l_packref (@{$l_xmlref->{packages}->{package}}) {
      my $l_name = $l_packref->{name};
      if ($l_name eq $l_package) {
         debug_print("Package $l_package found in dragon.xml install file");
         my $l_repo = $l_packref->{repo};
         my $l_version = $l_packref->{version};
         my $l_genero = $l_packref->{genero};
         update_package($l_repo, $l_name, $l_version, $l_genero);
         $l_found = 1;
         last;
      }
   }

   println("Package $l_package was not found in your dragon.xml file") unless $l_found == 1;

}

sub update_all_packages {

   my $l_xmlref = get_install_list();

   foreach my $l_packref (@{$l_xmlref->{packages}->{package}}) {
      my $l_name = $l_packref->{name};
      my $l_repo = $l_packref->{repo};
      my $l_version = $l_packref->{version};
      my $l_genero = $l_packref->{genero};
      debug_print("Updating package $l_name from repo $l_repo");
      update_package($l_repo, $l_name, $l_version, $l_genero);
   }

}

sub write_repo_file {
   my $l_name = shift;
   my $l_url = shift;
   my @l_headers = @_;

   my $l_filepath = get_user_dir() . "/" . $l_name . ".xml";
   open my $l_repo_handler, '>:encoding(iso-8859-1)', $l_filepath or die "open($l_filepath): $!";
   debug_print("Writing to repo file $l_filepath");

   my $l_hashref = {};
   $l_hashref->{$l_name}->{name} = $l_name;
   $l_hashref->{$l_name}->{url} = $l_url;
   @{$l_hashref->{$l_name}->{header}} = @l_headers;
   debug_print("Repo file contains: " . Dumper($l_hashref));
   XMLout($l_hashref, RootName => 'repo', OutputFile => $l_repo_handler);
   close $l_repo_handler;
   println("Repo file $l_filepath created");

}

sub read_repo_file {

   my $l_name = shift;
   my $l_filepath = get_user_dir() . "/" . $l_name . ".xml";

   if (! -f $l_filepath) {
      die "Repo file $l_filepath does not exist!\n";
   }
   debug_print("Reading repo file $l_filepath");
   my $ref = XMLin($l_filepath, ForceArray => qr/header$/);

   debug_print("read_repo_file returning " . Dumper($ref));
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
         debug_print("Processing repo file $filename");
      } elsif ($filename =~ /(.*)\.default/i) {
         $repos{$1} = 1;
         debug_print("Found default repo $1");
      }
   }
   closedir($dh);

   debug_print("get_repo_list returning " . Dumper(%repos));
   return %repos;

}

sub get_default_repo {

   my %l_repo_list = get_repo_list();

   for my $l_repo (keys %l_repo_list) {
      if ($l_repo_list{$l_repo} == 1) {
         debug_print("get_default_repo returning $l_repo");
         return $l_repo;
      }
   }

   debug_print("get_default_repo returning empty string, no default repo found");
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
         debug_print("Removing the old default repo file $l_old_default");
         last;
      }
   }

   open DEFAULTFILE, "> $l_repo_default" || die "Cannot create $l_repo_default for writing: $! \n";
   print DEFAULTFILE $l_name . "\n";
   close DEFAULTFILE;
   debug_print("Created new default repo file $l_repo_default");

}

sub remove_repo {

   my $l_name = shift;
   my $l_repo_xml = get_user_dir() . "/" . $l_name . ".xml";
   my $l_repo_default = get_user_dir() . "/" . $l_name . ".default";

   if (-f $l_repo_default) {
      unlink $l_repo_default;
      debug_print("Removing file $l_repo_default");
   }

   if (-f $l_repo_xml) {
      unlink $l_repo_xml;
      println("Repo $l_name has been removed");
   } else {
      println("Repo $l_name does not exist");
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
      println("Error: A package was not specified");
      create_usage();
      return;
   }

   if (defined $options{d}) {
      $l_directory = $options{d};
      debug_print("Using create directory $l_directory");
   }

   create_package($l_package_name, $l_directory);

}

sub create_usage {

   println("Usage: dragon.pl create -p [package] -d [directory]");
   println("Description: Create a Genero package");
   println("\tOption\t\tDescription");
   println("\t------\t\t-----------");
   println("\t-p\t\t(Required) Name of the package, example: com.fourjs.Example");
   println("\t-d\t\t(Optional) Directory path where the root package directory exists, example 'build'");

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
      println("Package repository not defined");
      install_usage();
   }

   my $l_package = "";
   if (defined $options{p}) {
      $l_package = $options{p};
   } else {
      println("Package is missing or invalid");
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
      println("Genero version has not been specified");
      install_usage();
   }

   #Get the repo url and HTTP headers
   my $l_url = $l_repo_info->{$l_repo}->{url};
   my @l_headers = ();
   if (defined $l_repo_info->{$l_repo}->{header}) {
      @l_headers = @{$l_repo_info->{$l_repo}->{header}};
   }
   debug_print("Using HTTP headers");
   debug_print(@l_headers);

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

   println("Usage: dragon.pl install -p [package] -r [repo] -v [version] -g [genero-version]");
   println("Description: Install a new package in the current working directory");
   println("\tOption\t\tDescription");
   println("\t------\t\t-----------");
   println("\t-p\t\t(Required) Name of the package, example: com.fourjs.Example");
   println("\t-r\t\t(Optional) Use a named repo defined with dragon.pl repo, will use the default if not specified");
   println("\t-v\t\t(Optional) Install a specific version of the package, will install the latest if not specified");
   println("\t-g\t\t(Required) Install a version compatible with a specific Genero version");

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

   println("Usage: dragon.pl update -p [package]");
   println("Description: Updates packages based on what is in dragon.xml, you can alternatively update just one package");
   println("\tOption\t\tDescription");
   println("\t------\t\t-----------");
   println("\t-p\t\t(Optional) Name of the package, example: com.fourjs.Example");

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
      println("dragon.pl - Artifact Repositories defined");
      foreach my $key (keys(%repos)) {
         if ($repos{$key} == 1) {
            println("\tRepository Name: $key (default)");
         } else {
            println("\tRepository Name: $key");
         }
         my $ref = read_repo_file($key);
         println("\tRepository URL: " . $ref->{$key}->{url} . "\n");
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
         println("No repo named $l_name has been defined!");
      }
   }

   #Remove the specified repo
   if (defined $options{r}) {
      my $repo_name = $options{r};
      remove_repo($repo_name);
   }

}

sub repo_usage {

   println("Usage: dragon.pl repo -l -r [repo name] -a [repo name] -d [repo name] -k [header key info] -u [repo root URL]");
   println("Description: Create a Genero package");
   println("\tOption\t\tDescription");
   println("\t------\t\t-----------");
   println("\t-l\t\tList all the repos defined by the user");
   println("\t-r\t\tRemove a repo defined for the user");
   println("\t-a\t\tAdd a new repo for Genero packages");
   println("\t-d\t\tSet the specified repo as the default for Genero packages");
   println("\t-k\t\tSpecify HTTP request header information, use a comma to separate if there are multiple,");
   println("\t\t\t  example: \"X-JFrog-Art-Api: XYZe1kWXuIqV833907QwXzfGiUUdYGuPXnTLFv59EhvRNh6JjMPnUqNq38W9MMFsinTYKgSAt\"");
   println("\t-u\t\tSpecify HTTP request root URL for the package repo,");
   println("\t\t\t  example: https://fourjsusa.jfrog.io/artifactory/genero-tools");

}

sub dragon_usage {

   println("Usage: dragon.pl [create|install|update|remove|repo] [options]");
   println("Description: The dragon.pl Genero package manager allows users to manage the package dependencies\n");

   create_usage();
   println("");

   repo_usage();
   println("");

   install_usage();
   println("");

   update_usage();
   println("");

}

my $cmd = shift;
dragon_usage() && exit 1 unless defined $cmd;

if ($cmd eq "debug") {
   $debug_mode = 1;
   $cmd = shift;
}

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

