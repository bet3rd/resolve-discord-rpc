#!/usr/bin/perl
# Discord Rich Presence for DaVinci Resolve.
#
# Runs in the background as a launch agent. It sleeps while Resolve is closed;
# when Resolve opens, it starts collector.lua under fuscript (Resolve's script
# interpreter) to read what's happening in Resolve and shows it on Discord
# through Discord's IPC socket. The presence clears when Resolve quits.
#
# Only core Perl modules are used, so it runs on the /usr/bin/perl that ships
# with macOS.

use strict;
use warnings;
use utf8;

use File::Basename qw(dirname);
use Getopt::Long;
use IO::Select;
use IO::Socket::UNIX;
use JSON::PP;
use POSIX qw(strftime);
use Time::HiRes qw(time sleep);

use constant {
  OP_HANDSHAKE => 0,
  OP_FRAME     => 1,
  OP_CLOSE     => 2,
  OP_PING      => 3,
  OP_PONG      => 4,

  RECONNECT_DELAY     => 5,
  COLLECTOR_RETRY     => 5,
  IDLE_POLL_INTERVAL  => 3,
  # Discord rate-limits SET_ACTIVITY to about 5 updates per 20 seconds.
  MIN_UPDATE_INTERVAL => 4,
  MAX_LOG_SIZE        => 1024 * 1024,
};

# Discord application "DaVinci Resolve"; its name is what shows after
# "Playing". Can be overridden with "clientId" in config.json.
use constant DEFAULT_CLIENT_ID => '';
# Image URL (or uploaded asset name) for the large image.
use constant DEFAULT_LARGE_IMAGE => '';

# Plain descriptions rather than page names: most people seeing the status
# don't know what the "Fairlight" or "Deliver" page is.
my %PAGE_ACTIVITY = (
  media     => 'Organizing media',
  cut       => 'Editing a video',
  edit      => 'Editing a video',
  fusion    => 'Creating visual effects',
  color     => 'Color grading',
  fairlight => 'Mixing audio',
  deliver   => 'Preparing an export',
  photo     => 'Editing photos',
);

my $support_dir = "$ENV{HOME}/Library/Application Support/resolve-discord-rpc";
my $config_path = "$support_dir/config.json";
my $collector_path = dirname(__FILE__) . '/collector.lua';
my $fuscript = '/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript';

GetOptions(
  'config=s'    => \$config_path,
  'collector=s' => \$collector_path,
  'fuscript=s'  => \$fuscript,
) or die "usage: $0 [--config FILE] [--collector FILE] [--fuscript PATH]\n";

$| = 1;
truncate STDOUT, 0 if -f STDOUT && (-s STDOUT // 0) > MAX_LOG_SIZE;

my $json = JSON::PP->new->utf8->canonical;

sub log_msg {
  printf "[%s] %s\n", strftime('%Y-%m-%d %H:%M:%S', localtime), join('', @_);
}

# --- config -----------------------------------------------------------------

my $config = {};
my $config_mtime = -1;

sub load_config {
  my $mtime = (stat $config_path)[9] // 0;
  return if $mtime == $config_mtime;
  $config_mtime = $mtime;

  my $loaded = {};
  if ($mtime && open my $fh, '<', $config_path) {
    my $raw = do { local $/; <$fh> };
    close $fh;
    $loaded = eval { $json->decode($raw) };
    unless (ref $loaded eq 'HASH') {
      log_msg "Ignoring $config_path: not valid JSON";
      $loaded = {};
    }
  }

  $config = {
    clientId     => DEFAULT_CLIENT_ID,
    largeImage   => DEFAULT_LARGE_IMAGE,
    showProject  => 1,
    showTimeline => 0,
    %$loaded,
  };
  log_msg 'No Discord application ID set; add "clientId" to ' . $config_path
    unless length($config->{clientId} // '');
}

# --- Resolve ----------------------------------------------------------------

my $resolve_pid;
my $session_start;
my $info;              # latest snapshot from the collector
my ($collector_fh, $collector_pid, $collector_buffer);
my $next_collector_at = 0;

sub stop_collector {
  return unless $collector_fh;
  kill 'TERM', $collector_pid;
  close $collector_fh;
  undef $collector_fh;
  undef $collector_pid;
}

sub start_collector {
  $next_collector_at = time + COLLECTOR_RETRY;
  $collector_pid = open $collector_fh, '-|', $fuscript, '-l', 'lua', $collector_path;
  unless ($collector_pid) {
    log_msg "Couldn't start $fuscript: $!";
    undef $collector_fh;
    return;
  }
  $collector_buffer = '';
  log_msg "Started collector (pid $collector_pid)";
}

sub read_collector {
  my $read = sysread $collector_fh, my $chunk, 65536;
  unless ($read) {
    log_msg 'Collector exited';
    stop_collector();
    return;
  }
  $collector_buffer .= $chunk;
  while ($collector_buffer =~ s/^(.*)\n//) {
    my $line = $1;
    # fuscript prints a banner before the script's own output.
    next unless $line =~ /^\{/;
    my $parsed = eval { $json->decode($line) } or next;
    $info = $parsed;
  }
}

sub track_resolve {
  return if $resolve_pid && kill 0, $resolve_pid;

  my ($pid) = `pgrep -x Resolve 2>/dev/null` =~ /(\d+)/;
  return if !$pid && !$resolve_pid;

  if ($pid) {
    log_msg "DaVinci Resolve started (pid $pid)";
    $session_start = int(time * 1000);
  } else {
    log_msg 'DaVinci Resolve quit';
    stop_collector();
    undef $info;
  }
  $resolve_pid = $pid;
  $next_collector_at = 0;
}

# --- Discord IPC ------------------------------------------------------------

my @socket_dirs = grep { defined && length } @ENV{qw(XDG_RUNTIME_DIR TMPDIR TMP TEMP)};
chomp(my $darwin_tmp = `getconf DARWIN_USER_TEMP_DIR 2>/dev/null` // '');
push @socket_dirs, $darwin_tmp if length $darwin_tmp;
push @socket_dirs, '/tmp';

my $sock;              # connected socket, or undef
my $sock_client_id;    # client id the socket handshook with
my $ready = 0;         # READY received
my $sent_key;          # last activity sent, to skip duplicate updates
my $last_sent_at = 0;
my $next_connect_at = 0;
my $last_error = '';
my $buffer = '';
my $nonce = 0;

sub socket_paths {
  my %seen;
  return grep { !$seen{$_}++ } map {
    (my $dir = $_) =~ s{/+$}{};
    map { "$dir/discord-ipc-$_" } 0 .. 9;
  } @socket_dirs;
}

sub disconnect {
  my ($reason) = @_;
  if ($sock) {
    log_msg "Disconnected from Discord: $reason";
    close $sock;
  }
  undef $sock;
  undef $sent_key;
  $ready = 0;
  $buffer = '';
  $next_connect_at = time + RECONNECT_DELAY;
}

sub send_frame {
  my ($op, $payload) = @_;
  return unless $sock;
  my $body = $json->encode($payload);
  my $frame = pack('VV', $op, length $body) . $body;
  local $SIG{PIPE} = 'IGNORE';
  my $written = syswrite $sock, $frame;
  disconnect("write failed: $!") unless defined $written && $written == length $frame;
}

sub connect_discord {
  my ($client_id) = @_;
  $next_connect_at = time + RECONNECT_DELAY;

  for my $path (socket_paths()) {
    next unless -S $path;
    my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path) or next;
    $sock = $s;
    $sock_client_id = $client_id;
    $last_error = '';
    log_msg "Connected to $path, handshaking with client id $client_id";
    send_frame(OP_HANDSHAKE, { v => 1, client_id => "$client_id" });
    return;
  }

  my $error = 'Discord is not running (no IPC socket found)';
  log_msg $error if $error ne $last_error;
  $last_error = $error;
}

# Discord rejects details/state/text fields outside 2..128 characters.
sub fit_text {
  my ($text) = @_;
  return undef unless defined $text && length $text;
  $text = substr($text, 0, 127) . "\x{2026}" if length $text > 128;
  $text .= "\x{2800}" while length $text < 2;
  return $text;
}

sub set_activity {
  my ($activity) = @_;
  my %args = (pid => $resolve_pid + 0);
  $args{activity} = $activity if $activity;
  send_frame(OP_FRAME, { cmd => 'SET_ACTIVITY', args => \%args, nonce => ++$nonce . "-$$" });
}

sub handle_frame {
  my ($op, $body) = @_;
  my $payload = eval { $json->decode($body) } // {};

  if ($op == OP_PING) {
    send_frame(OP_PONG, $payload);
  } elsif ($op == OP_CLOSE) {
    disconnect("closed by Discord: " . ($payload->{message} // $body));
  } elsif ($op == OP_FRAME) {
    my $evt = $payload->{evt} // '';
    if ($evt eq 'READY') {
      $ready = 1;
      log_msg "Discord ready (user: " . ($payload->{data}{user}{username} // '?') . ")";
    } elsif ($evt eq 'ERROR') {
      log_msg "Discord error: " . ($payload->{data}{message} // $body);
    }
  }
}

sub read_discord {
  my $read = sysread $sock, my $chunk, 65536;
  unless ($read) {
    disconnect(defined $read ? 'socket closed' : "read failed: $!");
    return;
  }
  $buffer .= $chunk;

  while (length $buffer >= 8) {
    my ($op, $len) = unpack 'VV', $buffer;
    last if length $buffer < 8 + $len;
    my $body = substr $buffer, 8, $len;
    substr($buffer, 0, 8 + $len) = '';
    handle_frame($op, $body);
    last unless $sock;
  }
}

# Waits up to $timeout seconds for output from Discord or the collector.
sub pump {
  my ($timeout) = @_;
  my $select = IO::Select->new(grep { defined } $sock, $collector_fh);
  unless ($select->count) {
    sleep $timeout;
    return;
  }
  for my $fh ($select->can_read($timeout)) {
    if ($sock && $fh == $sock) {
      read_discord();
    } elsif ($collector_fh && $fh == $collector_fh) {
      read_collector();
    }
  }
}

# --- presence ---------------------------------------------------------------

sub build_activity {
  my %activity = (
    state      => $PAGE_ACTIVITY{ $info->{page} // '' } // 'Working in DaVinci Resolve',
    timestamps => { start => $session_start },
    assets     => { large_text => 'DaVinci Resolve' },
  );
  $activity{assets}{large_image} = $config->{largeImage} if length($config->{largeImage} // '');

  if (my $render = $info->{render}) {
    $activity{state} = defined $render->{percent}
      ? sprintf('Rendering · %d%%', $render->{percent})
      : 'Rendering';
  }

  my @details;
  push @details, $info->{project} if $config->{showProject} && defined $info->{project};
  push @details, $info->{timeline} if $config->{showTimeline} && defined $info->{timeline};
  $activity{details} = join ' · ', @details if @details;

  for my $key (qw(details state)) {
    my $text = fit_text($activity{$key});
    defined $text ? ($activity{$key} = $text) : delete $activity{$key};
  }
  return \%activity;
}

sub shutdown_daemon {
  my ($reason) = @_;
  log_msg "Exiting: $reason";
  if ($sock && $ready) {
    set_activity(undef);
    pump(0.5);
  }
  close $sock if $sock;
  stop_collector();
  exit 0;
}

$SIG{$_} = sub { shutdown_daemon("received SIG$_[0]") } for qw(TERM INT HUP);

# --- main loop --------------------------------------------------------------

log_msg "Started (pid $$)";

while (1) {
  load_config();
  track_resolve();

  unless ($resolve_pid) {
    disconnect('DaVinci Resolve is closed') if $sock;
    sleep IDLE_POLL_INTERVAL;
    next;
  }

  start_collector() if !$collector_fh && time >= $next_collector_at;

  my $client_id = $config->{clientId} // '';
  if ($sock && $client_id ne $sock_client_id) {
    set_activity(undef) if $ready;
    disconnect('client id changed');
    $next_connect_at = 0;
  }

  connect_discord($client_id)
    if !$sock && $info && length $client_id && time >= $next_connect_at;

  if ($sock && $ready && $info && time - $last_sent_at >= MIN_UPDATE_INTERVAL) {
    my $activity = build_activity();
    my $key = $json->encode($activity);
    if (!defined $sent_key || $key ne $sent_key) {
      set_activity($activity);
      $sent_key = $key;
      $last_sent_at = time;
      log_msg "Set activity: $key";
    }
  }

  pump(1);
}
