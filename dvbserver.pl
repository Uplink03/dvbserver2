#!/usr/bin/perl -w
# dvbserver.pl
#
#  dvbserver.pl is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
# Summary
#   A simple HTTP server to stream audio from DVB-T stations on Linux systems.
#   The primary goal is to provide DVB Radio to squeezecenter from Logitech (see http://www.slimdevices.com)
#
# Changes
#   Version 1.0 Graham Chapman - 6th November 2008
#     First Release!
#   Version 1.1 Graham Chapman - 8th November 2008
#     Use direct http and ts2radio instead of mplayer to get stream
#        ts2radio is included in the distribution
#     Use icy-metadata to get program details to squeezecentre
#   Version 2.0 Graham Chapman - 11th November 2008
#     Remove dependancy on getstream and ts2radio binaries - just use perl module Linux::DVB instead
#     Include DVB-S and DVB-C (untested) support.
#   Version 2.1 Graham Chapman - 13th November 2008
#     Minor updates - clean disconnects and disconnect when client stops taking data 
# 
# See README for full details

use strict;
use IO::Socket;
use IO::Select;
use IO::Handle;
use Linux::DVB;
use Audio::Radio::V4L;
use IPC::Open2;
use Fcntl;
use POSIX;

############
# Defaults #
############

# DVB Adapter ID 
my $dvbadapter=3;
# Channels.conf file
my $conf = "/etc/dvbserver.conf"; 
# TCP Get the port to serve on
my $port = 9001;   
# Opttional filter - I use the lame extra to get 44.1KHz streams for squeezeslave - if not using squeezeslave this isn't needed
#my $filter = "";
my $filter = "lame --resample 44.1 --mp2input - - 2>/dev/null";
# Verbose flag
my $debug = 0;

################################

# Hash for channel list
my %channels;
# Incoming Connection IP
my $localaddr;
# Icy metadata flag
my $icyflag = 0;
# Remember last metadat to save repeats
my $lastmetadata = "";
# Current Program Details
my @proginfo = ("","");
# PID of the child process managing the frontend
my $frontendpid;
# Interface types
my @types = ("DVB-S","DVB-C","DVB-T");
# Tuning flag
my $retuned = 0;

# Output to STDERR
select(STDERR);

# Process command line
while ($_ = shift @ARGV)
{
   if ($_ eq "-d")
   {
      $debug = 1;
   }
   elsif ($_ eq "-p")
   {
      $port = shift @ARGV;
   }
   elsif ($_ eq "-c")
   {
      $conf = shift @ARGV;
   }
   elsif ($_ eq "-a")
   {
      $dvbadapter = shift @ARGV;
   }
   elsif ($_ =~ "-+h.*")
   {
      print "dvbsever.pl - Serve DVB Audio by http\n";
      print " usage: dvbsever.pl [-d] [-p port] [-c channels.conf] [-a adapter] [-help]\n";
      print "  where:\n";
      print "   -p port          TCP port to listen on [" . $port . "]\n";
      print "   -c channels.conf zap format channel list (from dvbscan) [" . $conf . "]\n";
      print "   -a adapter       DVB adapter to use (/dev/dvb/adapter?) [" . $dvbadapter. "]\n";
      print "   -d               Enable verose mode\n";
      print "   -h | --help      This information\n";
      exit (1);
   }
}

# Reap children - If frontend process dies, we quit
$SIG{CHLD} = \&REAPER;
sub REAPER
{
   my $pid = 1;

   while ($pid > 0)
   {
      $pid = waitpid(-1,WNOHANG);
      die ("Frontend handler stopped unexpectedly!") if (WIFEXITED($?) && ($pid == $frontendpid));
   }
}

# SIGUSR1 means a return suceeded
$SIG{USR1} = \&RETUNEOK;
sub RETUNEOK
{
   $retuned=1;
   logit("Got USR1\n");
}

# SIGUSR2 means a return failed
$SIG{USR2} = \&RETUNEBAD;
sub RETUNEBAD
{
   $retuned=-1;
   logit("Got USR2\n");
}

# Check frontend type and read channel info
{
   my $fe;
   eval { $fe = Linux::DVB::Frontend->new ( "/dev/dvb/adapter$dvbadapter/frontend0", 1); };
   die "Error opening front end: /dev/dvb/adapter$dvbadapter/frontend0" if ($@);
   my $type = $types[$fe->{'type'}];
   close ($fe->fh);
   %channels = readConf($conf,$type) or die "Failed to read config file: $conf";
}

# Fork frontend manager
die "Can't Fork: $!" unless defined ($frontendpid = open (FRONTEND, "|-"));
FRONTEND->autoflush(1);
if ($frontendpid == 0)  # Frontend Process
{
   my $fe;
   my %currentchannel = ();
   my $lasttune = 0;
   # Open Frontend
   eval { $fe = Linux::DVB::Frontend->new ( "/dev/dvb/adapter$dvbadapter/frontend0", 1); };
   die "Error opening front end: /dev/dvb/adapter$dvbadapter/frontend0" if ($@);
   
   while (<STDIN>) # Clients send tuning requests on STDIN
   {
      logit ("Frontend got: $_\n");
      # Proccess tuning requests
      if (/^Tune:(.*);PID:(.*);$/)
      {
         my $channel=$1;
         my $requestpid=$2;
         my $match = 1;
         my $type = $channels{$channel}{"type"};

         # Check current multiplex first
	 for ('realfrequency','polarization','symbol_rate','fec_inner','modulation','inversion','bandwidth','code_rate_HP','code_rate_LP','constellation','transmission_mode','guard_interval','hierarchy_information')
	 {
	    $currentchannel{$_} = " " if (!defined($currentchannel{$_})); # Avoid unititialised errors
	    $match = 0 if (defined($channels{$channel}{$_}) && ($currentchannel{$_} ne $channels{$channel}{$_}));
	 }
         $retuned = 0;
 	 if ($match or ((time() - $lasttune >20) and tune($fe,$channel) and ($lasttune = time()))) # Don't allow retune more than every 20s
	 {
            logit ("Tuning OK. (Match=$match)\n");
            kill("USR1",$requestpid); # It worked
	    %currentchannel = %{$channels{$channel}};
	 }
 	 else
	 {
            logit ("Tuning Issue\n");
            kill("USR2",$requestpid); # It failed
	 }
      }   
   }
   close($fe->fh);
   exit 0;
}

# Start listening for HTTP requests
my $serversock = IO::Socket::INET->new ( 
				LocalPort => $port, 
				Proto => 'tcp',
				Listen => 10, 
				Reuse => 1,
				)
or die "Bind to TCP port $port failed: $@n";

logit ("Waiting for connections\n");
# Wait for connections
while(1)
{
    my $connection = $serversock->accept;
    if ($connection)
    {
       my $child;
       # Perform the fork or exit
       die "Can't fork: $!" unless defined ($child = fork());
       if ($child == 0)
       {   # I'm the child!
           # Close the child's listen socket, we dont need it.
           $serversock->close;
        
           # Call the main child rountine
           serveHTTP($connection);
        
          # If the child returns, then just exit;
           exit 0;
       } 
       else
       {   # I'm the parent!
           # Close the connection, the parent has already passed it off to a child.
           $connection->close();
       }
    }
    # Go back and listen for the next connection!
} 

# Tune to requested frequency
sub tune
{
   my $fe = shift;
   my $chan = shift;
   my %chan_info;
   my $count = 0;

   # Get channel details
   %chan_info = %{$channels{$chan}};
   return(0) unless (%chan_info);

   if ($types[$fe->{'type'}] eq "DVB-S")
   {
      logit("  Voltage:" . $fe->diseqc_voltage($chan_info{'voltage'}) ."\n");
      logit("  Tone:" . $fe->diseqc_tone ($chan_info{'tone'}) ."\n");
   }
   logit ("Tuning to $chan_info{'realfrequency'}  Lock: " . $fe->read_status . "\n"); 
   return(0) unless $fe->set(%chan_info);
   until ( ($fe->read_status & FE_HAS_LOCK) or ($count >20))
   {
      logit ("   Lock: " . $fe->read_status . "\n"); 
      $count++;
      sleep 1;
   }
   return(0) if ($count >20); # 20second timeout
   logit ("Tuned!   Lock: " . $fe->read_status . "\n"); 
   return(1);
}

# Service HTTP request
# Valid requests are:
#    "/" or ""          Returns HTML channel list with links to channel PLS files
#    "/TV.pls"          Returns a PLS file of TV channels
#    "/Radio.pls"       Returns a PLS file of audio only (Radio) channels
#    "/All.pls"         Returns a PLS file of all channels
#    "/channelname.pls" Returns a PLS file pointing to the mp2 stream for "channelname"
#    "/channelname.pls" Returns a PLS file pointing to the mp2 stream for "channelname"
#    "/channelname.mp2" Returns a raw (mp2) stream of "channelname"
# All other requests will result in a 404 error
#
# Requests for a channel on a different multiplex will be blocked (404 sent) for 30seconds after a retune. 
# This attempts to prevent competing clients retries causing a retune loop!
#
# Arguments: 
#    1 - socket handle to send to
sub serveHTTP
{
   my $socket = shift;
   my $channel = "";
   my $retdata;
   my $type;
   $localaddr = $socket->sockhost;

   logit ("Connection from " . $socket->peerhost . " to " . $localaddr . "\n");

   # Read the socket
   while(<$socket>) 
   { 
      if ($_ =~ /^\r/) 
      {
         # break the loop when we get the empty line at the end of the request
         last;
      }
      else 
      {
         # If its a get request then parse it
         if ( $_ =~ /^GET/ ) 
         {
            $_ =~ /GET (.*) /;
            $channel = $1; # This is the requested channel
         }
         # Is Icy-Metadata Requested?
         if ( $_ =~ /^Icy-Metadata:\s+1/ ) 
         {
            $icyflag = 1;
	    logit("  Icy Metadat enabled.\n");
         }
	 logit("*  Header:$_");
      }
   }
    
   # Return channel listing 
   if (length($channel) < 2) 
   {	
      logit ("Returning Channel List\n");
      getChanListHTML ($socket);
   }
   # Return channel playlist
   elsif ($channel eq "/TV.pls" or $channel eq "/Radio.pls" or $channel eq "/All.pls") 
   {	
      # Strip leading / and extention
      $channel =~ s/\///;
      $channel =~ s/\.pls$//;
      logit ("Returning $channel Playlist\n");
      $retdata = getChanListPLS ($socket,$channel);
   }
   else  # Seach for $channel in the config file
   {
      # Fix up and special characters. eg %20 > " "
      $channel =~ s/\%(..)/chr(hex("$1"))/eg;
      # Strip leading / and extention
      $channel =~ s/\///;
      $channel =~ s/\.(...)$//;
      $type = $1 ? $1 : "";
      logit ("Request for $channel type $type\n");

      if ($channels{$channel})  # Check for valid channel
      {
  	 if ($type eq "mp2")
         {
           logit ("Send tuning request\n");
	    print FRONTEND "Tune:$channel;PID:$$;\n";
	    my $count = 0;
	    while ($retuned==0 && $count < 20)
	    {
               sleep 1;
	       $count++;
	    }
	    if ($retuned < 1)
	    { 
               logit("No tuning signal received!!\n") if ($count > 19); # Tuning hasn't returned signal - strange!
               logit("Tuning Failed\n"); 
	       send404($socket);
   	    }
	    # Stream raw mp2 data
	    logit ("Sending MP2\n");
	    send404($socket) unless &streamRaw ($socket,$channel);
         }
	 else
	 {
	    # Send Playlist
            logit ("Sending PLS\n");
            getChannelPLS ($socket,$channel);
         }
      }
      else
      {
         logit ("Not found.\n");
         send404($socket);
      }
   }
   logit ("Closing connection.\n");
   # close the socket and exit this thread.
   $socket->close();
   exit (0);
}


# Send a PLS file for only the requested channel
#   Useful to get player to display a friendly channel name rather than the full WAV stream URL
# Arguments: 
#    1 - socket handle to send to
#    2 - name of required channel
sub getChannelPLS
{
   my $socket = shift;
   my $channel = shift;
   my $retdata;

   $retdata = "[playlist]\n";
   $retdata .= "NumberOfEntries=1\n\n";
   $retdata .= "File1=http://$localaddr:$port/$channel.mp2\n"; 
   $retdata .= "Title1=$channel\n"; 
   $retdata .= "Length1=-1\n"; 
   print $socket "HTTP/1.1 200 OK\r\n";
   print $socket "Content-Type: audio/x-scpls\r\n";
   print $socket "Content-Disposition: attachment; filename=\"$channel.pls\"\r\n";
   print $socket "Content-Length: " . length($retdata) . "\r\n";
   print $socket "Cache-Control: no-cache\r\n";
   print $socket "Connection: close\r\n\r\n";
   print $socket $retdata;
}

# Send a raw (mp2) stream over HTTP of the channel requested
#   Opens DVB Mux device twice, once to filter Audio and once for EIT data
#   Optionaly filters audio if required.
#   Ends if no audio data for 10 seconds.
# Arguments: 
#    1 - socket handle to send to
#    2 - channel name
# Returns:
#    1 if sucessful, 0 otherwise
sub streamRaw
{
   my $socket = shift;
   my $channel = shift;
   my $id = $channels{$channel}{'id'};
   my $data;
   my $datasize = 8192;
   my $converter;
   my $selection;
   my @ready;
   my $fh;
   my $flags;
   my $icymetaint = 32768;
   my $lasticy = 0 ;
   my $metadata;
   my $length;
   my $stream;
   my $dmx;
   my $dmx_eit;
   my $last_data;

   # Open a 2 way pipe to the TS->MP2/3 converter
   if ($filter)
   {
      $converter = $filter;
      $converter =~ s/PID/$channels{$channel}{'apid'}/;
      $converter =~ s/SID/$channels{$channel}{'sid'}/;
      logit ("Starting converter: $converter\n");
      unless (open2(\*RADIOOUT,\*RADIOIN,$converter))
      {
         logit ("Failed to open '$converter'.\n");
         close($stream);
         return(0);
      }
      $flags = '';
      unless (($flags = fcntl(RADIOIN, F_GETFL, 0)) and fcntl(RADIOIN, F_SETFL, $flags | O_NONBLOCK))
      {
         close(RADIOIN);
         close(RADIOOUT);
         logit ("Failed to set filter to non-blocking\n");
         return(0);
      }
   }

   eval {
      # Open demux for Audio
      $dmx = new Linux::DVB::Demux  "/dev/dvb/adapter$dvbadapter/demux0";
      $dmx->buffer (16384);
      $dmx->pes_filter ($channels{$channel}{'apid'}, DMX_IN_FRONTEND,DMX_OUT_TAP, DMX_PES_OTHER, 0);
      logit (" ($$)Setting Up Demux for $channels{$channel}{'apid'}\n");
      die ("Failed to start Demux!") unless $dmx->start; 
      # Open demux for EIT
      $dmx_eit = new Linux::DVB::Demux  "/dev/dvb/adapter$dvbadapter/demux0";
      $dmx_eit->buffer (16384);
      $dmx_eit->sct_filter (0x12, chr(0x4e), chr(0xff), 0, DMX_CHECK_CRC);
      $dmx_eit->start; 
   };
   if ($@)
   {
      if ($filter)
      {
         close(RADIOIN);
         close(RADIOOUT);
      }
      logit (" Demux Open failed: $@\n");
      return(0);
   }

   # Set socket to non-blocking
   ($flags = fcntl($socket, F_GETFL, 0)) and fcntl($socket, F_SETFL, $flags | O_NONBLOCK);
   
   logit ("Streaming\n");
   syswrite ($socket,"HTTP/1.1 200 OK\r\n");
   syswrite ($socket,"Content-Type: audio/mpeg\r\n");
   syswrite ($socket,"Cache-Control: no-cache\r\n");
   syswrite ($socket,"icy-name: $channel\r\n");
   syswrite ($socket,"icy-metaint: $icymetaint\r\n\r\n") if ($icyflag);
   $selection = new IO::Select;
   $selection->add(\*RADIOOUT) if ($filter);
   $selection->add($dmx->fh);
   $selection->add($dmx_eit->fh);

   $last_data=time();
   READ_LOOP: while (@ready = $selection->can_read(20)) 
   {
      #logit("$$ ");
      foreach $fh (@ready) 
      {
         if (sysread($fh,$data,$datasize))
	 {
   	    if ($fh == $dmx->fh && $filter) # Filter if required
	    {
	       syswrite RADIOIN,$data;
   	       #logit ("  " . length($data) . " => filter\n");
	    }
	    elsif ($fh == $dmx_eit->fh) # Process EIT
	    {
	       for (split("\n",processEIT($data, $channel)))
	       {
       	          if (/^Name:(.*)$/)
		  {
		     $proginfo[0]=$1;
	             logit ("    Name= '$1' from EIT \n");
		  }
		  elsif (/^Description:(.*)$/)
		  {
		     $proginfo[1]=$1;
	  #           logit ("    Desc= '$1' from EIT\n");
		  }
		  else
		  {
	             logit ("    Got '$_' from EIT\n");
		  }
               }
	    }
	    else # Must be Audio - send to socket
	    {
	       $last_data=time();
	       if ($icyflag) # Add metadata if required
	       {
                  $lasticy += length ($data); 
		  if ($lasticy >= $icymetaint) 
		  {
		     $metadata=makeMetadata(join(" - ", @proginfo));
                     #logit ("  ($$) Metadata '" . join(" - ", @proginfo) . "'\n");
		     #logit ("  ($$)Last     '" . $lastmetadata . "'\n");
                     logit ("  ($$) Adding metadata '$metadata'\n") if (length($metadata) > 1);
		     $length=length($data)+$icymetaint-$lasticy;
		     $data = substr($data,0,$length) . $metadata . substr($data,$length);
		     $lasticy -= $icymetaint;
		  }
	       #logit ("  ($$)" . length($data) . " => socket\n");
	       }
	       last READ_LOOP unless ($socket->peerhost and syswrite $socket,$data);
	    }
	       last READ_LOOP if (time() - $last_data > 10); # Stop if no data for 10 seconds
	 }
	 else
	 {
            last READ_LOOP;
	 }
      }
   }
   $dmx->stop;
   $dmx_eit->stop;
   close($dmx->fh);
   close($dmx_eit->fh);
   close(RADIOOUT) if ($filter);
   close(RADIOIN) if ($filter);
   logit ("\nDone.\n");
   return(1);
}

# Process EIT data
#   Returns a string of Program Name and Description if available
# Arguments:
#    1 - EIT Data
#    2 - Channel Name
sub processEIT
{
   my $si_decoded_hashref = Linux::DVB::Decode::si $_[0]; 
   my $sid = $channels{$_[1]}{'sid'};
   my %event;
   my @events;
   my %descriptors;
   my $count;
   my ($d,$k,$v);
   my $retval = "";

   if ($si_decoded_hashref->{'service_id'} == $sid)
   {
      for (@{$si_decoded_hashref->{'events'}})
      {
         %event=%{$_};
         #logit ("  Running: " . $_->{'running_status'} . "\n");

         %descriptors=();
	 @events=@{$event{'descriptors'}};
         $count=0;
	 foreach $d (@events)
         {
            if ($d->{'type'} == 77)
            {
               $retval="Name:$d->{'event_name'}\nDescription:$d->{'text'}\n" if ($_->{'running_status'} == 4);
            }
#	    $count++;
#            logit ("  $count\n");
#            while ( ($k,$v) = each(%$d) ) 
#	    {
#	       if ($k eq "services")
#	       {
#                  logit ("    $k: " . join(",",values(%{$$v[0]})) . "\n");
#               }
#	       else
#	       {
#	          logit ("    $k:'$v'\n");
#               }
#	       $descriptors{$k} = $v;
#            }
         }
      }
   }
   return ($retval);
}

# Build stream metadata entry
#   Returns only 0 if no changes
# Arguments
#    1 - Metadata string
sub makeMetadata
{
   my $metadata = shift;
   my $length;

   if ( $metadata eq $lastmetadata) 
   {
      return chr(0);
   }
   else
   {
      $lastmetadata=$metadata;
      $metadata = "StreamTitle='$metadata';";
      $length=length($metadata);
      $metadata .= chr(0) x ((16 - $length) % 16);
      $length=length($metadata);
      $metadata = chr($length/16) . $metadata;
      return $metadata;
   }
}

# Send a PLS file containing the type of channels requested
# Arguments: 
#    1 - socket handle to send to
#    2 - "Radio" for Audio only channels, "TV" for TV Channels, or "All" for everything
sub getChanListPLS
{
   my $socket = shift;
   my $retdata;
   my $entry;
   my %entry;
   my $list = "";
   my $count = 0;

   for $entry ( sort keys %channels )
   {
      %entry=%{$channels{$entry}};

      # Return oly required channels
      if (($entry{'vpid'} > 0 xor $_[0] eq "Radio") or $_[0] eq "All")
      {
         $count++;
         $list .= "File$count=http://$localaddr:$port/$entry.mp2\n"; 
         $list .= "Title$count=$entry\n"; 
         $list .= "Length$count=-1\n"; 
      }
   }

   $retdata = "[playlist]\n"; 
   $retdata .= "NumberOfEntries=$count\n\n";
   $retdata .= $list;

   print $socket "HTTP/1.1 200 OK\r\n";
   print $socket "Content-Type: audio/x-scpls\r\n";
   print $socket "Content-Length: " . length($retdata) . "\r\n";
   print $socket "Cache-Control: no-cache\r\n";
   print $socket "Connection: close\r\n\r\n";
   print $socket $retdata;
}

# Send HTML list of available channels
# Arguments: 
#    1 - socket handle to send to
sub getChanListHTML
{
   my $socket = shift;
   my $retdata;
   my $entry;
   my %entry;
   my $radio = "";
   my $tv = "";

   $retdata =  "<html><head><title>Channels</title></head><body>\n";
   for $entry ( sort keys %channels )
   {
      %entry=%{$channels{$entry}};

      # TV
      if ($entry{'vpid'} > 0 )
      {
         $tv .= "<a href=\"/$entry.pls\">$entry</a>";
         $tv .= " - (<a href=\"/$entry.mp2\">Play Now</a>)";
	 $tv .= "<br>\n";
      }
      # Radio
      else
      {
         $radio .= "<a href=\"/$entry.pls\">$entry</a>";
         $radio .= " - (<a href=\"/$entry.mp2\">Play Now</a>)";
	 $radio .= "<br>\n";
      }

   }
   if ($radio) 
   {
      $retdata .=  "<h1>Radio</h1>\n";
      $retdata .= $radio;
   }
   if ($tv)
   {
      $retdata .=  "<h1>TV</h1>\n";
      $retdata .= $tv;
   }
   $retdata .=  "<h1>Playlists</h1>\n";
   $retdata .= "<a href=\"/All.pls\">All Channels</a><br>\n";
   $retdata .= "<a href=\"/TV.pls\">TV Channels</a><br>\n";
   $retdata .= "<a href=\"/Radio.pls\">Radio Channels</a><br>\n";
   $retdata .= "</body></html>\n";

   print $socket "HTTP/1.1 200 OK\r\n";
   print $socket "Content-Type: text/html\r\n";
   print $socket "Content-Length: " . length($retdata) . "\r\n";
   print $socket "Cache-Control: no-cache\r\n";
   print $socket "Connection: close\r\n\r\n";
   print $socket $retdata;
}

# Read dvbscan style channels.conf file into %channels (a hash of channel names to hashes of config params))
#
# Returns:
#   1 on success, 0 otherwise
sub readConf
{
   my $entry;
   my $conf = shift;
   my $type = shift;
   my %channels;

   return() unless open(CONFIG_FILE,"<$conf");
    
   while(<CONFIG_FILE>)
   {
      $entry=();

      if ($type eq "DVB-T")
      {
         ($entry->{'name'},$entry->{'frequency'},$entry->{'inversion'},$entry->{'bandwidth'},$entry->{'code_rate_HP'},$entry->{'code_rate_LP'},$entry->{'constellation'},$entry->{'transmission_mode'},$entry->{'guard_interval'},$entry->{'hierarchy_information'},$entry->{'vpid'},$entry->{'apid'},$entry->{'sid'}) = split(':',$_);
	 for ('inversion','bandwidth','code_rate_HP','code_rate_LP','constellation','transmission_mode','guard_interval','hierarchy_information')
	 {
	    # Eval constant names, with basic regex check to prevent abusive code in channel defs!
            $entry->{$_} = eval $entry->{$_} if ($entry->{$_} =~ /^[A-Z_0-9]*$/);
	 }
	 $entry->{'realfrequency'} = $entry->{'frequency'};
      }
      elsif ($type eq "DVB-S")  # Assumes universal LNB in use!
      {
         ($entry->{'name'},$entry->{'realfrequency'},$entry->{'polarisation'},$entry->{'fec_inner'},$entry->{'symbol_rate'},$entry->{'vpid'},$entry->{'apid'},$entry->{'sid'}) = split(':',$_);
         if($entry->{'realfrequency'} >11700)
	 {
	    $entry->{'frequency'} = $entry->{'realfrequency'} - 10600;  # High Band
	    $entry->{'tone'} = 1;
	 }
	 else
	 {
	    $entry->{'frequency'} = $entry->{'realfrequency'} - 9750;   # Low Band
	    $entry->{'tone'} = 0;
	 }
	 $entry->{'voltage'} = ($entry->{'polarisation'} eq 'v') ? 13 : 18; # Polorisation selection voltage
	 $entry->{'inversion'} = 0;
	 $entry->{'symbol_rate'} *= 1000;
	 $entry->{'frequency'} *= 1000;
	 $entry->{'realfrequency'} *= 1000;
      }
      else # Assume DVB-C
      {
         ($entry->{'name'},$entry->{'frequency'},$entry->{'inversion'},$entry->{'symbol_rate'},$entry->{'fec_inner'},$entry->{'modulation'},$entry->{'vpid'},$entry->{'apid'},$entry->{'sid'}) = split(':',$_);
	 for ('inversion','symbol_rate','fec_inner')
	 {
	    # Eval constant names, with basic regex check to prevent abusive code in channel defs!
            $entry->{$_} = eval $entry->{$_} if ($entry->{$_} =~ /^[A-Z_0-9]*$/);
	 }
	 $entry->{'realfrequency'} = $entry->{'frequency'};
	 $entry->{'inversion'} = INVERSION_AUTO;
      }

      chomp($entry->{'sid'});
      $entry->{'type'} = $type;

      # Only add channels with Audio Available
      if ($entry->{'apid'} > 0)
      {
         $channels{$entry->{'name'}}=$entry;
      }
   }
   close(CONFIG_FILE);
   return(%channels);
}

# Send an HTML 404 Error
# Arguments: 
#    1 - socket handle to send to
sub send404
{
   my $socket = shift;
   my $retdata;
   $retdata =  "<html><head><title>Not Found</title></head><body>404 - Page not available</body></html>\n";

   print $socket "HTTP/1.1 404 Not Found\r\n";
   print $socket "Content-Type: text/html\r\n";
   print $socket "Content-Length: " . length($retdata) . "\r\n";
   print $socket "Connection: close\r\n\r\n";
   print $socket $retdata;
}

# Log to STDERR if debug enabled (-d)
# Arguments: 
#    1 - Message to display
sub logit
{
   print STDERR $_[0] if $debug;
}
