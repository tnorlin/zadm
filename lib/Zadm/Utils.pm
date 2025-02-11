package Zadm::Utils;
use Mojo::Base -base, -signatures;

use Cpanel::JSON::XS;
use Data::Processor;
use File::Temp;
use IPC::Open3;
use Mojo::Log;
use Mojo::Exception;
use Mojo::File;
use Mojo::Home;
use Mojo::IOLoop::Subprocess;
use Mojo::Loader qw(find_modules load_class);
use Mojo::Promise;
use POSIX qw(isatty);
use Regexp::IPv4 qw($IPv4_re);
use Regexp::IPv6 qw($IPv6_re);
use Sun::Solaris::Kstat;
use Text::ParseWords qw(shellwords);
use Zadm::Privilege qw(:CONSTANTS privSet);
use Zadm::Validator;

# constants
my $CONFFILE = Mojo::Home->new->detect(__PACKAGE__)->rel_file('etc/zadm.conf')->to_string; # CONFFILE

my @FORMATS = qw(json toml yaml);

my $SCHEMA = sub($self) {
    my $sv = Zadm::Validator->new(log => $self->log);
    return {
    CONFIG  => {
        optional => 1,
        members  => {
            format          => {
                optional    => 1,
                description => 'config format',
                example     => '"format" : "toml"',
                validator   => $sv->elemOf(@FORMATS),
            },
        },
    },
    CONSOLE  => {
        optional => 1,
        members  => {
            auto_connect    => {
                optional    => 1,
                description => 'automatically connect to the console when booting a zone',
                example     => '"auto_connect" : "on"',
                validator   => $sv->elemOf(qw(on off)),
            },
            auto_disconnect => {
                optional    => 1,
                description => 'automatically disconnect from the console when a zone is shutdown',
                example     => '"auto_disconnect" : "on"',
                validator   => $sv->elemOf(qw(on off)),
            },
            escape_char     => {
                optional    => 1,
                description => 'console escape character',
                example     => '"escape_char" : "_"',
                validator   => $sv->regexp(qr/^.$/, 'expected a single character'),
            },
        },
    },
    SNAPSHOT => {
        optional => 1,
        members  => {
            prefix          => {
                optional    => 1,
                description => 'prefix for snapshot names created by zadm',
                example     => '"prefix" : "zadm__"',
                validator   => $sv->regexp(qr/^[-\w]*$/, 'expected a string containing alphanumeric, _ or - characters'),
            },
        },
    },
    VNC      => {
        optional => 1,
        members  => {
            bind_address    => {
                optional    => 1,
                description => 'default address to bind',
                example     => '"bind_address" : "[::1]"',
                validator   => $sv->regexp(qr/^(?:\*|$IPv4_re|(?:\[?(?:$IPv6_re|::)\]?))$/, 'not a valid IP address'),
            },
            novnc_path      => {
                optional    => 1,
                description => 'path to noVNC',
                example     => '"novnc_path" : "/path/to/novnc"',
                validator   => $sv->noVNC,
            },
            auto_connect    => {
                optional    => 1,
                description => 'automatically connect as soon as the page has finished loading (webvnc only)',
                example     => '"auto_connect" : "on"',
                validator   => $sv->bool,
            },
        },
    },
}};

# commands
my %CMDS = (
    zoneadm     => '/usr/sbin/zoneadm',
    zonecfg     => '/usr/sbin/zonecfg',
    zlogin      => '/usr/sbin/zlogin',
    zonename    => '/usr/bin/zonename',
    bhyvectl    => '/usr/sbin/bhyvectl',
    dladm       => '/usr/sbin/dladm',
    pptadm      => '/usr/sbin/pptadm',
    editor      => $ENV{VISUAL} || $ENV{EDITOR} || '/usr/bin/vi',
    zfs         => '/usr/sbin/zfs',
    pkg         => '/usr/bin/pkg',
    nc          => '/usr/bin/nc',
    pager       => $ENV{PAGER} || '/usr/bin/less -eimnqX',
    domainname  => '/usr/bin/domainname',
    dispadmin   => '/usr/sbin/dispadmin',
    getconf     => '/usr/bin/getconf',
    pagesize    => '/usr/bin/pagesize',
    swap        => '/usr/sbin/swap',
    ipf         => '/usr/sbin/ipf',
    ipfstat     => '/usr/sbin/ipfstat',
    ipmon       => '/usr/sbin/ipmon',
    ipnat       => '/usr/sbin/ipnat',
    file        => '/usr/bin/file',
    dd          => '/usr/bin/dd',
    uefivars    => '/opt/ooce/bin/uefivars',
    bhyve_boot  => '/usr/lib/brand/bhyve/boot',
);

my %ENVARGS = map {
    $_ => [ shellwords($ENV{'__ZADM_' . uc ($_) . '_ARGS'} // '') ]
} keys %CMDS;

my $ZPATH = ($ENV{__ZADM_ALTROOT} // '') . '/etc/zones';

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has gconf    => sub($self) {
    my $cfgFile = Mojo::File->new($CONFFILE);
    return {} if !-r $cfgFile;

    $self->log->debug("Global config found at '$cfgFile'. Validating...");

    my $cfg = $self->json->decode($cfgFile->slurp);
    my $dp  = Data::Processor->new($self->$SCHEMA);
    my $ec  = $dp->validate($cfg);
    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}) . "\n");
    return $cfg;
};
has kstat    => sub { Sun::Solaris::Kstat->new };
has ncpus    => sub($self) { $self->readProc('getconf', [ qw(NPROCESSORS_ONLN) ])->[0] // 1 };
has shares   => sub($self) {
    return (($self->readProc('zonecfg', [ qw(-z global info cpu-shares) ])->[0] // '')
        =~ /cpu-shares:\s+(\d+)/)[0] // '1';
};
has pagesize => sub($self) { $self->readProc('pagesize')->[0] // 4096 };
has ram      => sub($self) {
    return $self->kstat->{unix}->{0}->{system_pages}->{physmem}
        * $self->pagesize;
};
has swap     => sub($self) {
    my $swap = $self->readProc('swap', [ '-s' ])->[0]
        or return 0;

    my ($used, $avail) = $swap =~ /(\d+)k\s+used,\s+(\d+)k\s+available$/
        or return 0;

    return ($used + $avail) * 1024;
};
has json     => sub($self) { Cpanel::JSON::XS->new->pretty->canonical(1) };
has conffmt  => sub($self) {
    $ENV{__ZADMTEST} || !$self->gconf->{CONFIG}->{format} ? 'json' : $self->gconf->{CONFIG}->{format}
};
has encconf  => sub($self) {
    return sub($data) { $self->encodeData($self->conffmt, $data) };
};
has decconf  => sub($self) {
    for ($self->conffmt) {
        /^json$/ && return sub($data) { $self->json->decode($data) };
        /^toml$/ && do {
            $self->loadMod('TOML::Tiny');
            # from_toml in list context will return an error string as second return value
            # make sure to call it in scalar context that it just returns the data
            # but dies on error
            return sub($data) { scalar TOML::Tiny::from_toml($data) };
        };
        /^yaml$/ && do {
            $self->loadMod('YAML::XS');
            return sub($data) { YAML::XS::Load($data) };
        };
    }
};

# private methods
my $edit = sub($self, $config) {
    my $suf  = $self->gconf->{CONFIG}->{format} || 'json';
    my $fh   = File::Temp->new(SUFFIX => ".$suf", OPEN => 0);
    my $file = Mojo::File->new($fh->filename);
    $file->spurt($config);

    my $mtime = $file->stat->mtime;

    local $@;
    eval {
        local $SIG{__DIE__};

        $self->exec('editor', [ $fh->filename ]);
    };
    if ($@) {
        # a return value of -1 indicats the editor could not be executed
        Mojo::Exception->throw("$@\n") if $? == -1;

        return (0, $config);
    }

    $config = $file->slurp;

    return ($file->stat->mtime != $mtime, $config);
};

my $getDsMntMap = sub($self, $mounted = 1) {
    if ($mounted) {
        open my $fh, '<', '/etc/mnttab'
            or Mojo::Exception->throw("ERROR: opening '/etc/mnttab' for reading: $!\n");

        return { map { /^(\S+)\s+(\S+)\s+zfs/ } (<$fh>) };
    }

    return { map { split /\s+/, $_, 2 } @{$self->readProc('zfs', [ qw(list -H -o), 'name,mountpoint' ])} };
};

# constructor
sub new($class, @args) {
    my $self = $class->SUPER::new(@args);

    # call gconf on instantiation for two reasons:
    # - fail immediately if the global config is incorrect and not
    #   when the config is accessed first
    # - the gconf attribute will be evaluated before we possibly
    #   fork and therefore would read/validate the config several times
    $self->gconf;

    return $self;
}

# public methods
sub encodeData($self, $fmt = 'json', $data = {}) {
    if (!grep { $_ eq $fmt } @FORMATS) {
        warn "WARNING: unknown format '$fmt', defaulting to json.\n";
        $fmt = 'json';
    }

    for ($fmt) {
        /^json$/ && return $self->json->encode($data);
        /^toml$/ && do {
            $self->loadMod('TOML::Tiny');
            return TOML::Tiny::to_toml($data) . "\n";
        };
        /^yaml$/ && do {
            $self->loadMod('YAML::XS');
            return YAML::XS::Dump($data);
        };
    }
}

sub getCmd($self, $cmd) {
    Mojo::Exception->throw("ERROR: command '$cmd' not defined.\n")
        if !exists $CMDS{$cmd};

    return shellwords($CMDS{$cmd});
}

sub readProc($self, $cmd, $args = []) {
    my @cmd = ($self->getCmd($cmd), @{$ENVARGS{$cmd}}, @$args);
    $self->log->debug(@cmd);

    open my $devnull, '>', File::Spec->devnull;
    my $pid = open3(undef, my $stdout, $devnull, @cmd);

    chomp (my @read = <$stdout>);

    waitpid $pid, 0;

    return \@read;
}

sub exec($self, $cmd, $args = [], $err = "executing '$cmd'", $fork = 0, $ret = 0) {
    my @cmd = ($self->getCmd($cmd), @{$ENVARGS{$cmd}}, @$args);
    $self->log->debug(@cmd);

    if ($fork) {
        if (defined (my $pid = fork)) {
            # exec should never return unless there was an error
            $pid || exec (@cmd)
                or Mojo::Exception->throw("ERROR: $err: $!\n");
        }
    }
    else {
        system (@cmd) && ($ret || Mojo::Exception->throw("ERROR: $err: $!\n"));
    }
}

sub edit($self, $zone, $prop = {}) {
    # backup current zone XML so it can be restored when things get hairy
    my $backcfg;
    my $backmod;

    my $xml = Mojo::File->new($ZPATH, $zone->name . '.xml');
    if (-r $xml) {
        $self->log->debug("backing up current zone config from $xml");

        $backmod = $xml->stat->mtime;
        $backcfg = $xml->slurp
    }

    my $istty  = $self->isaTTY || $ENV{__ZADMTEST};
    my $config = $self->encconf->($zone->config) if !%$prop && $istty;

    my $cfgValid = 0;

    while (!$cfgValid) {
        (my $mod, $config) = %$prop ? (1, '')
                           : $istty ? $self->$edit($config)
                           :          (1, join ("\n", @{$self->getSTDIN}));

        if (!$mod) {
            if ($zone->exists) {
                # restoring the zone XML config since it was changed but something went wrong
                if ($backmod && $backmod != $xml->stat->mtime) {
                    $self->log->warn('WARNING: restoring the zone config.');
                    $xml->spurt($backcfg);

                    return 0;
                }

                return 1;
            }

            print "You did not make any changes to the default configuration,\n",
                'do you want to create the zone with all defaults [Y/n]? ';
            chomp (my $check = <STDIN>);

            return 0 if $check =~ /^no?$/i;
        }

        local $@;
        $self->log->debug('validating', uc ($self->conffmt));
        my $cfg = eval {
            local $SIG{__DIE__};
            %$prop ? { %{$zone->config}, %$prop } : $self->decconf->($config);
        };
        if ($@) {
            my ($pre, $off, $post) = $@ =~ /^(.+at)\s+character\s+offset\s+(\d+)\s+(.+\))\s+at\s+/;

            if (defined $pre && defined $off && defined $post) {
                # cut the JSON string at the offset where decoding failed
                my $jsonerr = substr $config, 0, $off;
                # count newlines
                my $nl = $jsonerr =~ s/(?:\r\n|\n|\r)//sg;
                $@ = "$pre line " . ($nl + 1) . " $post\n";
            }
        }
        else {
            $self->log->debug("validating config");
            $cfgValid = eval {
                local $SIG{__DIE__};
                $zone->setConfig($cfg);
            };
        }
        if ($@) {
            print $@;

            my $check;
            if (!$istty || %$prop) {
                $check = 'no';
            }
            else {
                print 'Do you want to retry [Y/n]? ';
                chomp ($check = <STDIN>);
            }

            if ($check =~ /^no?$/i) {
                # restoring the zone XML config since it was changed but something went wrong
                if ($backmod && $backmod != $xml->stat->mtime) {
                    $self->log->warn('WARNING: restoring the zone config.');
                    $xml->spurt($backcfg);
                }

                return 0;
            }
        }
    }

    return 1;
}

sub edit_s($self, $zone, $prop = {}) {
    my $p = Mojo::Promise->new;

    $zone->zones->images->editing(1) if $zone->opts->{image};

    Mojo::IOLoop::Subprocess->new->run(
        sub($subprocess) {
            return ($self->edit($zone, $prop), $zone->config);
        },
        sub($subprocess, $err, $res, $cfg) {
            warn $err if $err;
            # if $res is false the user aborted, in this case we don't wait for
            # all promises to be settled but exit
            exit 1 if !$res || $err;

            # update the zone config of the main instance with
            # the changes from edit in the forked instance
            $zone->config($cfg);

            $zone->zones->images->editing(0) if $zone->opts->{image};
            $p->resolve(1);
        }
    );

    return $p;
}

sub getZfsProp($self, $ds, $prop = []) {
    return {} if !@$prop;

    my $vals = $self->readProc('zfs', [ qw(get -H -o value), join (',', @$prop), $ds ]);

    return { map { $prop->[$_] => $vals->[$_] } (0 .. $#$prop) };
}

sub getFileType($self, $data, $suffix = '') {
    my $f = Mojo::File->new(File::Temp->new($suffix ? (SUFFIX => $suffix) : ()));
    $f->spurt($data);

    return $self->readProc('file', [ '-b', $f ])->[0];
}

sub domain($self) {
    my %domain;

    my ($domain) = $self->readProc('domainname')->[0] =~ /^\s*(\S+)/;

    -r '/etc/resolv.conf' && do {
        open my $fh, '<', '/etc/resolv.conf'
            or Mojo::Exception->throw("ERROR: cannot read /etc/resolv.conf: $!\n");

        while (<$fh>) {
            my ($key, $val) = /^\s*(\S+)\s+(\S+)/
                or next;

            for ($key) {
                /^nameserver$/ && do {
                    push @{$domain{resolvers}}, $val;

                    last;
                };
                /^domain$/ && do {
                    $domain{'dns-domain'} = $val;

                    last;
                };
                /^search$/ && do {
                    $domain{'dns-domain'} ||= $val;

                    last;
                };
            }
        }
    };

    $domain{'dns-domain'} = $domain if $domain;

    return \%domain;
}

sub scheduler($self) {
    my $dispadmin = $self->readProc('dispadmin', [ qw(-d) ]);

    return { 'cpu-shares' => 1 } if grep { /^FSS/ } @$dispadmin;
    return {};
}

sub prettySize($self, $size, $format = '%.0f%s', $units = [ qw(B K M G T P E) ]) {
    my $i = $size <= 0 ? 0 : int (log ($size) / log (1024.0));

    return sprintf($format, $size / 1024 ** $i, $units->[$i]);
}

sub getPhysMem($self) {
    return $self->prettySize($self->ram);
}

sub loadTemplate($self, $file, $name = '') {
    my $template = Mojo::File->new($file)->slurp;
    # TODO: add handler for more modular transforms, for now we just support __ZONENAME__
    $template =~ s/__ZONENAME__/$name/g if $name;

    # TODO: add proper error handling
    return $self->decconf->($template);
}

sub getOverLink($self) {
    my $dladm = $self->readProc('dladm', [ qw(show-link -p -o), 'link,class' ]);
    return [ map { /^([^:]+):(?:phys|etherstub|aggr|overlay)/ } @$dladm ];
}

sub isVirtual($self) {
    my $method = (caller (1))[3];

    Mojo::Exception->throw("ERROR: '$method' is a pure virtual method and must be implemented in a derived class.\n");
}

sub isaTTY($self) {
    return isatty(*STDIN);
}

sub isPWHash($self, $str) {
    # since we are feeding the password to clound-init we use the same
    # logic for detecting whether the password is hashed or not

    return $str =~ /^\$(?:1|2a|2y|5|6)(?:\$[^\$]+){2}$/;
}

# non-boolean values are considered true
sub boolIsTrue($self, $val) {
    return $val && !grep { $_ eq $val } qw(false off no);
}

sub getSTDIN($self) {
    return $self->isaTTY() ? [] : [ split /\r\n|\n|\r/, do { local $/; <STDIN>; } ];
}

sub genmap($self, $arr) {
    return { map { $_ => undef } @$arr };
}

sub getMods($self, $namespace) {
    return [ grep { !/base$/ } find_modules $namespace ];
}

sub loadMod($self, $mod) {
    Mojo::Exception->throw("ERROR: failed to load '$mod'.\n")
        if load_class $mod;
}

sub snapshot($self, $op, $ds, $snap = '', $args = []) {
    Mojo::Exception->throw("ERROR: dataset must not be empty.\n") if !$ds;

    return $self->readProc('zfs', [ qw(list -H -t snapshot -d1 -o name -s creation), @$args, $ds ])
        if $op eq 'list';

    Mojo::Exception->throw("ERROR: snapshot must not be empty.\n") if !$snap;

    privSet({ add => 1, inherit => 1 }, PRIV_SYS_MOUNT);
    $self->exec('zfs', [ $op, @$args, "$ds\@$snap" ]);
    privSet({ remove => 1, inherit => 1 }, PRIV_SYS_MOUNT);
}

sub getMntDs($self, $path, $mounted = 1) {
    my $mnt = $self->$getDsMntMap($mounted);

    $path =~ s!/+$!!; # remove trailing slashes

    $mnt->{$_} eq $path && return $_ for keys %$mnt;

    return undef;
}

sub getDsMnt($self, $ds, $mounted = 1) {
    my $mnt = $self->$getDsMntMap($mounted);

    return $mnt->{$ds};
}

sub isArrRef($self, $val) {
    return $val && ref $val eq ref [];
}

sub isHashRef($self, $val) {
    return $val && ref $val eq ref {};
}

1;

__END__

=head1 COPYRIGHT

Copyright 2021 OmniOS Community Edition (OmniOSce) Association.

=head1 LICENSE

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.
This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
more details.
You should have received a copy of the GNU General Public License along with
this program. If not, see L<http://www.gnu.org/licenses/>.

=head1 AUTHOR

S<Dominik Hassler E<lt>hadfl@omnios.orgE<gt>>

=head1 HISTORY

2020-10-24 had Initial Version

=cut
