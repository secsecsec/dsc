package DSC::extractor;

use DBI;
use XML::Simple;
use POSIX;
use Digest::MD5;
#use File::Flock;
use File::NFSLock;
use Time::HiRes; # XXX for debugging

use strict;

BEGIN {
	use Exporter   ();
	use vars       qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
	$VERSION     = 1.00;
	@ISA	 = qw(Exporter);
	@EXPORT      = qw(
		&yymmdd
		&get_dbh
		&get_server_id
		&get_node_id
		&data_table_exists
		&create_data_table
		&create_data_indexes
		&data_table_names
		&data_index_names
		&read_data
		&write_data
		&write_data2
		&write_data3
		&write_data4
		&grok_1d_xml
		&grok_2d_xml
		&grok_array_xml
		&elsify_unwanted_keys
		&replace_keys
		$datasource
		$username
		$password
		$db_insert_suffix
		$SKIPPED_KEY
		$SKIPPED_SUM_KEY
	);
	%EXPORT_TAGS = ( );     # eg: TAG => [ qw!name1 name2! ],
	@EXPORT_OK   = qw();
}
use vars      @EXPORT;
use vars      @EXPORT_OK;

END { }


# globals
$SKIPPED_KEY = "-:SKIPPED:-";	# must match dsc source code
$SKIPPED_SUM_KEY = "-:SKIPPED_SUM:-";	# must match dsc source code
$datasource = undef;
$username = undef;
$password = undef;
$db_insert_suffix = 'new';

sub yymmdd {
	my $t = shift;
	my @t = gmtime($t);
	POSIX::strftime "%Y%m%d", @t;
}

# was used by old LockFile::Simple code
#
sub lockfile_format {
	my $fn = shift;
	my @x = stat ($fn);
	unless (defined ($x[0]) && defined($x[1])) {
		open(X, ">$fn");
		close(X);
	}
	@x = stat ($fn);
	die "$fn: $!" unless (defined ($x[0]) && defined($x[1]));
	'/tmp/' . join('.', $x[0], $x[1], 'lck');
}

sub lock_file {
	my $fn = shift;
#	return new File::Flock($fn);
	return File::NFSLock->new($fn, 'BLOCKING');
}

sub get_dbh {
    # my $dbstart = Time::HiRes::gettimeofday;
    my $dbh = DBI->connect($datasource, $username, $password, {
	AutoCommit => 0
	}); # XXX
    if (!defined $dbh) {
	print STDERR "error connecting to database: $DBI::errstr\n";
	return undef;
    }
    # printf "opened db connection in %d ms\n",
    #     (Time::HiRes::gettimeofday - $dbstart) * 1000;
    return $dbh;
}

sub data_table_exists($$) {
    my ($dbh, $tabname) = @_;
    my $sth = $dbh->prepare_cached(
	"SELECT 1 FROM pg_tables WHERE tablename = ?");
    $sth->execute("${tabname}_new");
    my $result = scalar $sth->fetchrow_array;
    $sth->finish;
    return $result;
}

#
# Create db table(s) for a dataset.
# A dataset is split across two tables:
# ${tabname}_new contains the current day's data.  It has no indexes, so the
#   once-per-minute inserts of new data are fast; and it's small, so the
#   plotter's queries aren't too slow despite the lack of indexes.
# ${tabname}_old contains older data.  It has the indexes needed to make the
#   plotter's queries fast (the indexes are created in a separate function).
#   One-day chunks are periodically moved from _new to _old.
# A view named ${tabname} is defined as the union of the _new and _old tables,
# for querying convenience.  However, inserting/deleting/updating a view is
# not portable across database engines, so we will do those operations
# directly on the underlying tables.
#
sub create_data_table {
    my ($dbh, $tabname, $dbkeys) = @_;

    print "creating table $tabname\n";
    print STDERR "dbkeys: ", join(', ', @$dbkeys), "\n";
    my $def =
	"(" .
	"  server_id     SMALLINT NOT NULL, " .
	"  node_id       SMALLINT NOT NULL, " .
	"  start_time    INTEGER NOT NULL, " . # unix timestamp
	# "duration      INTEGER NOT NULL, " . # seconds
	(join '', map("$_ VARCHAR NOT NULL, ", grep(/^key/, @$dbkeys))) .
	"  count         INTEGER NOT NULL " .
	## Omitting primary key and foreign keys improves performance of inserts	## without any real negative impacts.
	# "CONSTRAINT dsc_$tabname_pkey PRIMARY KEY (server_id, node_id, start_time, key1), " .
	# "CONSTRAINT dsc_$tabname_server_id_fkey FOREIGN KEY (server_id) " .
	# "    REFERENCES server (server_id), " .
	# "CONSTRAINT dsc_$tabname_node_id_fkey FOREIGN KEY (node_id) " .
	# "    REFERENCES node (node_id), " .
	")";

    for my $sfx ('old', 'new') {
	my $sql = "CREATE TABLE ${tabname}_${sfx} $def";
	# print STDERR "SQL: $sql\n";
	$dbh->do($sql);
    }
    my $sql = "CREATE OR REPLACE VIEW $tabname AS " .
	"SELECT * FROM ${tabname}_old UNION ALL " .
	"SELECT * FROM ${tabname}_new";
    # print STDERR "SQL: $sql\n";
    $dbh->do($sql);
}

# returns a reference to an array of data table names
sub data_table_names {
    my ($dbh) = @_;
    return $dbh->selectcol_arrayref("SELECT viewname FROM pg_views " .
	"WHERE schemaname = 'dsc' AND viewname LIKE 'dsc_%'");
}

# returns a reference to an array of data table index names
sub data_index_names {
    my ($dbh) = @_;
    return $dbh->selectcol_arrayref("SELECT indexname FROM pg_indexes " .
	"WHERE schemaname = 'dsc' AND indexname LIKE 'dsc_%'");
}

sub create_data_indexes {
    my ($dbh, $tabname) = @_;
    $dbh->do("CREATE INDEX ${tabname}_old_time ON ${tabname}_old(start_time)");
}

sub get_server_id($$) {
    my ($dbh, $server) = @_;
    my $server_id;
    my $sth = $dbh->prepare("SELECT server_id FROM server WHERE name = ?");
    $sth->execute($server);
    my @row = $sth->fetchrow_array;
    if (@row) {
	$server_id = $row[0];
    } else {
	$dbh->do('INSERT INTO server (name) VALUES(?)', undef, $server);
	$server_id = $dbh->last_insert_id(undef, undef, 'server', 'server_id');
    }
    return $server_id;
}

sub get_node_id($$$) {
    my ($dbh, $server_id, $node) = @_;
    my $node_id;
    my $sth = $dbh->prepare(
	"SELECT node_id FROM node WHERE server_id = ? AND name = ?");
    $sth->execute($server_id, $node);
    my @row = $sth->fetchrow_array;
    if (@row) {
	$node_id = $row[0];
    } else {
	$dbh->do('INSERT INTO node (server_id, name) VALUES(?,?)',
	    undef, $server_id, $node);
	$node_id = $dbh->last_insert_id(undef, undef, 'node', 'node_id');
    }
    return $node_id;
}

#
# read from a db table into a hash
# TODO: if the requested time range does not overlap the ${tabname}_new table,
# we can omit that table from the query.
#
sub read_data {
	my ($dbh, $href, $type, $server_id, $node_id, $start_time, $end_time, $dbkeys) = @_;
	my $nl = 0;
	my $tabname = "dsc_$type";
	my $sth;
	my $start = Time::HiRes::gettimeofday;

	my $needgroup =
	    defined $end_time && !(grep /^start_time/, @$dbkeys) ||
	    !defined $node_id && !(grep /^node_id/, @$dbkeys) ||
	    !(grep /^key/, @$dbkeys);
	my @params = ();
	my $sql = "SELECT " . join(', ', @$dbkeys);
	$sql .= $needgroup ? ", SUM(count) " : ", count ";
	$sql .= "FROM $tabname WHERE ";
	if (defined $end_time) {
	    $sql .= "start_time >= ? AND start_time < ? ";
	    push @params, $start_time, $end_time;
	} else {
	    $sql .= "start_time = ? ";
	    push @params, $start_time;
	}
	$sql .= "AND server_id = ? ";
	push @params, $server_id;
	if (defined $node_id) {
	    $sql .= "AND node_id = ? ";
	    push @params, $node_id;
	}
	$sql .= "GROUP BY " . join(', ', @$dbkeys) if ($needgroup);
	# print STDERR "SQL: $sql;  PARAMS: ", join(', ', @params), "\n";
	$sth = $dbh->prepare($sql);
	$sth->execute(@params);

	while (my @row = $sth->fetchrow_array) {
	    $nl++;
	    if (scalar @$dbkeys == 1) {
		$href->{$row[0]} = $row[1];
	    } elsif (scalar @$dbkeys == 2) {
		$href->{$row[0]}{$row[1]} = $row[2];
	    } elsif (scalar @$dbkeys == 3) {
		$href->{$row[0]}{$row[1]}{$row[2]} = $row[3];
	    }
	}
	$dbh->commit;
	# print "read $nl rows from $tabname\n";
	#printf STDERR "read $nl rows from $tabname in %d ms\n",
	#    (Time::HiRes::gettimeofday - $start) * 1000;
	return $nl;
}

# read data in old flat file format (used by importer)
sub read_flat_data {
	my $href = shift;
	my $fn = shift;
	my $nl = 0;
	my $md = Digest::MD5->new;
	return 0 unless (-f $fn);
	if (open(IN, "$fn")) {
	    while (<IN>) {
		$nl++;
		if (/^#MD5 (\S+)/) {
			if ($1 ne $md->hexdigest) {
				warn "MD5 checksum error in $fn at line $nl\n".
					"found $1 expect ". $md->hexdigest. "\n".
					"exiting";
				return -1;
			}
			next;
		}
		$md->add($_);
		chomp;
		my ($k, %B) = split;
		$href->{$k} = \%B;
	    }
	    close(IN);
	}
	$nl;
}

#
# write 1-dimensional hash with time to table with 1 minute buckets
#
sub write_data {
	# parameter $t is ignored.
	my ($dbh, $A, $type, $server_id, $node_id, $t) = @_;
	my $tabname = "dsc_${type}_${db_insert_suffix}";
	my $start = Time::HiRes::gettimeofday;
	my $nl = 0;
	$dbh->do("COPY $tabname FROM STDIN");
	foreach my $t (keys %$A) {
	    my $B = $A->{$t};
	    foreach my $k (keys %$B) {
		$dbh->pg_putline("$server_id\t$node_id\t$t\t$k\t$B->{$k}\n");
		$nl++;
	    }
	}
	$dbh->pg_endcopy;
	printf "wrote $nl rows to $tabname in %d ms\n",
	    (Time::HiRes::gettimeofday - $start) * 1000;
}

# read data in old flat file format (used by importer)
sub read_flat_data2 {
	my $href = shift;
	my $fn = shift;
	my $nl = 0;
	my $md = Digest::MD5->new;
	return 0 unless (-f $fn);
	if (open(IN, "$fn")) {
	    while (<IN>) {
		$nl++;
		if (/^#MD5 (\S+)/) {
			if ($1 ne $md->hexdigest) {
				warn "MD5 checksum error in $fn at line $nl\n".
					"found $1 expect ". $md->hexdigest. "\n".
					"exiting";
				return -1;
			}
			next;
		}
		$md->add($_);
		chomp;
		my ($k, $v) = split;
		$href->{$k} = $v;
	    }
	    close(IN);
	}
	$nl;
}

# write 1-dimensional hash without time to table with 1 day buckets
#
sub write_data2 {
	my ($dbh, $href, $type, $server_id, $node_id, $t) = @_;
	my $tabname = "dsc_${type}_${db_insert_suffix}";
	my $start = Time::HiRes::gettimeofday;
	my $nl = 0;
	$dbh->do("COPY $tabname FROM STDIN");
	foreach my $k1 (keys %$href) {
	    $dbh->pg_putline("$server_id\t$node_id\t$t\t$k1\t$href->{$k1}\n");
	    $nl++;
	}
	$dbh->pg_endcopy;
	printf "wrote $nl rows to $tabname in %d ms\n",
	    (Time::HiRes::gettimeofday - $start) * 1000;
}

# read data in old flat file format (used by importer)
sub read_flat_data3 {
	my $href = shift;
	my $fn = shift;
	my $nl = 0;
	my $md = Digest::MD5->new;
	return 0 unless (-f $fn);
	if (open(IN, "$fn")) {
	    while (<IN>) {
		$nl++;
		if (/^#MD5 (\S+)/) {
			if ($1 ne $md->hexdigest) {
				warn "MD5 checksum error in $fn at line $nl\n".
					"found $1 expect ". $md->hexdigest. "\n".
					"exiting";
				return -1;
			}
			next;
		}
		$md->add($_);
		chomp;
		my ($k1, $k2, $v) = split;
		next unless defined($v);
		$href->{$k1}{$k2} = $v;
	    }
	    close(IN);
	}
	$nl;
}

# write 2-dimensional hash without time to table with 1 day buckets
#
sub write_data3 {
	my ($dbh, $href, $type, $server_id, $node_id, $t) = @_;
	my $tabname = "dsc_${type}_${db_insert_suffix}";
	my $start = Time::HiRes::gettimeofday;
	my $nl = 0;
	$dbh->do("COPY $tabname FROM STDIN");
	foreach my $k1 (keys %$href) {
		foreach my $k2 (keys %{$href->{$k1}}) {
		    $dbh->pg_putline("$server_id\t$node_id\t$t\t$k1\t$k2\t$href->{$k1}{$k2}\n");
		    $nl++;
		}
	}
	$dbh->pg_endcopy;
	printf "wrote $nl rows to $tabname in %d ms\n",
	    (Time::HiRes::gettimeofday - $start) * 1000;
}


# read data in old flat file format (used by importer)
sub read_flat_data4 {
	my $href = shift;
	my $fn = shift;
	my $nl = 0;
	my $md = Digest::MD5->new;
	return 0 unless (-f $fn);
	if (open(IN, "$fn")) {
	    while (<IN>) {
		$nl++;
		if (/^#MD5 (\S+)/) {
			if ($1 ne $md->hexdigest) {
				warn "MD5 checksum error in $fn at line $nl\n".
					"found $1 expect ". $md->hexdigest. "\n".
					"exiting";
				return -1;
			}
			next;
		}
		$md->add($_);
		chomp;
		my ($ts, %foo) = split;
		while (my ($k,$v) = each %foo) {
			my %bar = split(':', $v);
			$href->{$ts}{$k} = \%bar;
		}
	    }
	    close(IN);
	}
	$nl;
}

#
# write 2-dimensional hash with time to table with 1 minute buckets
#
sub write_data4 {
	# parameter $t is ignored.
	my ($dbh, $A, $type, $server_id, $node_id, $t) = @_;
	my $tabname = "dsc_${type}_${db_insert_suffix}";
	my $start = Time::HiRes::gettimeofday;
	my $nl = 0;
	my ($B, $C);
	$dbh->do("COPY $tabname FROM STDIN");
	foreach my $t (keys %$A) {
	    $B = $A->{$t};
	    foreach my $k1 (keys %$B) {
		next unless defined($C = $B->{$k1});
		foreach my $k2 (keys %$C) {
		    $dbh->pg_putline("$server_id\t$node_id\t$t\t$k1\t$k2\t$C->{$k2}\n");
		    $nl++;
		}
	    }
	}
	$dbh->pg_endcopy;
	printf "wrote $nl rows to $tabname in %d ms\n",
	    (Time::HiRes::gettimeofday - $start) * 1000;
}

##############################################################################

sub grok_1d_xml {
	my $fname = shift || die "grok_1d_xml() expected fname";
	my $L2 = shift || die "grok_1d_xml() expected L2";
	my $XS = new XML::Simple(searchpath => '.', forcearray => 1);
	my $XML = $XS->XMLin($fname);
	my %result;
	my $aref = $XML->{data}[0]->{All};
	foreach my $k1ref (@$aref) {
		foreach my $k2ref (@{$k1ref->{$L2}}) {
			my $k2 = $k2ref->{val};
			$result{$k2} = $k2ref->{count};
		}
	}
	($XML->{start_time}, \%result);
}

sub grok_2d_xml {
	my $fname = shift || die;
	my $L1 = shift || die;
	my $L2 = shift || die;
	my $XS = new XML::Simple(searchpath => '.', forcearray => 1);
	my $XML = $XS->XMLin($fname);
	my %result;
	my $aref = $XML->{data}[0]->{$L1};
	foreach my $k1ref (@$aref) {
		my $k1 = $k1ref->{val};
		foreach my $k2ref (@{$k1ref->{$L2}}) {
			my $k2 = $k2ref->{val};
			$result{$k1}{$k2} = $k2ref->{count};
		}
	}
	($XML->{start_time}, \%result);
}

sub grok_array_xml {
	my $fname = shift || die;
	my $L2 = shift || die;
	my $XS = new XML::Simple(searchpath => '.', forcearray => 1);
	my $XML = $XS->XMLin($fname);
	my $aref = $XML->{data}[0]->{All};
	my @result;
	foreach my $k1ref (@$aref) {
		my $rcode_aref = $k1ref->{$L2};
		foreach my $k2ref (@$rcode_aref) {
			my $k2 = $k2ref->{val};
			$result[$k2] = $k2ref->{count};
		}
	}
	($XML->{start_time}, @result);
}

sub elsify_unwanted_keys {
	my $hashref = shift;
	my $keysref = shift;
	foreach my $k (keys %{$hashref}) {
		next if ('else' eq $k);
		next if (grep {$k eq $_} @$keysref);
		$hashref->{else} += $hashref->{$k};
		delete $hashref->{$k};
	}
}

sub replace_keys {
	my $oldhash = shift;
	my $oldkeys = shift;
	my $newkeys = shift;
	my @newkeycopy = @$newkeys;
	my %newhash = map { $_ => $oldhash->{shift @$oldkeys}} @newkeycopy;
	\%newhash;
}

##############################################################################

1;
