#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 51;
#use Test::More 'no_plan';
use App::Sqitch;
use Test::NoWarnings;
use Path::Class;
use Test::Exception;
use Test::Dir;
use Test::File qw(file_exists_ok file_not_exists_ok);
use Test::File::Contents;
use Locale::TextDomain qw(App-Sqitch);
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::bundle';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'bundle command';

can_ok $CLASS, qw(
    dest_dir
    configure
    execute
    bundle_config
    bundle_plan
    bundle_scripts
    _mkpath
    _copy
);

is_deeply [$CLASS->options], [qw(
    dest_dir|dir=s
)], 'Should have dest_dir option';

is $bundle->dest_dir, dir('bundle'),
    'Default dest_dir should be bundle/';

is_deeply $bundle->_dir_map, {
    top_dir => [ $sqitch->top_dir, dir 'bundle'],
}, 'Dir map should have only top dir';

##############################################################################
# Test configure().

is_deeply $CLASS->configure($config, {}), {}, 'Default config should be empty';
is_deeply $CLASS->configure($config, {dest_dir => 'whu'}), {
    dest_dir => dir 'whu',
}, '--dest_dir should be converted to a path object by configure()';

chdir 't';
ok $sqitch = App::Sqitch->new(
    top_dir => dir 'sql',
), 'Load a sqitch sqitch object with top_dir';
$config = $sqitch->config;
my $dir = dir qw(_build sql);
is_deeply $CLASS->configure($config, {}), {
    dest_dir => $dir,
}, 'bundle.dest_dir config should be converted to a path object by configure()';

##############################################################################
# Load a real project.
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'another bundle command';

is $bundle->dest_dir, $dir, qq{dest_dir should be "$dir"};
is_deeply $bundle->_dir_map, {
    top_dir    => [ $sqitch->top_dir, dir qw(_build sql sql)],
    deploy_dir => [ dir(qw(sql deploy)), dir(qw(_build sql sql deploy)) ]
}, 'Dir map should have top and deploy dirs';

# Try pg project.
ok $sqitch = App::Sqitch->new(
    top_dir => dir 'pg',
), 'Load a sqitch sqitch object with pg top_dir';
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'pg bundle command';

is $bundle->dest_dir, $dir, qq{dest_dir should again be "$dir"};
is_deeply $bundle->_dir_map, {
    top_dir    => [ $sqitch->top_dir, dir qw(_build sql pg)],
    deploy_dir => [ dir(qw(pg deploy)), dir(qw(_build sql pg deploy)) ],
    revert_dir => [ dir(qw(pg revert)), dir(qw(_build sql pg revert)) ],
}, 'Dir map should have top, deploy, and revert dirs';

# Add a test directory.
my $test_dir = dir qw(pg test);
$test_dir->mkpath;
END { remove_tree $test_dir->stringify if -e $test_dir }
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'another pg bundle command';
is_deeply $bundle->_dir_map, {
    top_dir    => [ $sqitch->top_dir, dir qw(_build sql pg)],
    deploy_dir => [ dir(qw(pg deploy)), dir(qw(_build sql pg deploy)) ],
    revert_dir => [ dir(qw(pg revert)), dir(qw(_build sql pg revert)) ],
}, 'Dir map should still not have test dir';

# Now put something into the test directory.
$test_dir->file('something')->touch;
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'yet another pg bundle command';
is_deeply $bundle->_dir_map, {
    top_dir    => [ $sqitch->top_dir, dir qw(_build sql pg)],
    deploy_dir => [ dir(qw(pg deploy)), dir(qw(_build sql pg deploy)) ],
    revert_dir => [ dir(qw(pg revert)), dir(qw(_build sql pg revert)) ],
    test_dir   => [ dir(qw(pg test)),   dir(qw(_build sql pg test)) ],
}, 'Dir map should still now include test dir';

##############################################################################
# Test _mkpath.
my $path = dir 'delete.me';
dir_not_exists_ok $path, "Path $path should not exist";
END { remove_tree $path->stringify if -e $path }
ok $bundle->_mkpath($path), "Create $path";
dir_exists_ok $path, "Path $path should now exist";
is_deeply +MockOutput->get_debug, [[__x 'Created {file}', file => $path]],
    'The mkdir info should have been output';

# Create it again.
ok $bundle->_mkpath($path), "Create $path again";
dir_exists_ok $path, "Path $path should still exist";
is_deeply +MockOutput->get_debug, [], 'Nothing should have been emitted';

# Handle errors.
FSERR: {
    # Make mkpath to insert an error.
    my $mock = Test::MockModule->new('File::Path');
    $mock->mock( mkpath => sub {
        my ($file, $p) = @_;
        ${ $p->{error} } = [{ $file => 'Permission denied yo'}];
        return;
    });

    throws_ok { $bundle->_mkpath('foo') } 'App::Sqitch::X',
        'Should fail on permission issue';
    is $@->ident, 'bundle', 'Permission error should have ident "bundle"';
    is $@->message, __x(
        'Error creating {path}: {error}',
        path  => 'foo',
        error => 'Permission denied yo',
    ), 'The permission error should be formatted properly';
}

##############################################################################
# Test _copy().
my $file = file qw(sql deploy roles.sql);
my $dest = file $path, qw(deploy roles.sql);
file_not_exists_ok $dest, "File $dest should not exist";
ok $bundle->_copy($file, $dest), "Copy $file to $dest";
file_exists_ok $dest, "File $dest should now exist";
file_contents_identical $dest, $file, "Files $dest and $file should be equal";
is_deeply +MockOutput->get_debug, [[__x 'Created {file}', file => $dest->dir]],
    'The mkdir info should have been output';
is_deeply +MockOutput->get_info, [[__x(
    "Copying {source} -> {dest}",
    source => $file,
    dest   => $dest
)]], 'Copy message should have been emitted';

# Copy it again.
ok $bundle->_copy($file, $dest), "Copy $file to $dest again";
file_exists_ok $dest, "File $dest should still exist";
file_contents_identical $dest, $file,
    "Files $dest and $file should still be equal";
is_deeply +MockOutput->get_debug, [], 'Should have no mkdir output';
is_deeply +MockOutput->get_info, [[__x(
    "Copying {source} -> {dest}",
    source => $file,
    dest   => $dest
)]], 'Copy message should again have been emitted';

# Copy a different file.
my $file2 = file qw(sql deploy users.sql);
ok $bundle->_copy($file2, $dest), "Copy $file2 to $dest";
file_exists_ok $dest, "File $dest should now exist";
file_contents_identical $dest, $file2, "Files $dest and $file2 should be equal";
is_deeply +MockOutput->get_debug, [], 'Should still have no mkdir output';
is_deeply +MockOutput->get_info, [[__x(
    "Copying {source} -> {dest}",
    source => $file2,
    dest   => $dest
)]], 'Copy message should have been emitted';

COPYDIE: {
    # Make copy die.
    my $mocker = Test::MockModule->new('File::Copy');
    $mocker->mock(copy => sub { return 0 });
    throws_ok { $bundle->_copy($file, $dest) } 'App::Sqitch::X',
        'Should get exception when copy returns false';
    is $@->ident, 'bundle', 'Copy fail ident should be "bundle"';
    is $@->message, __x(
        'Cannot copy "{source}" to "{dest}": {error}',
        source => $file,
        dest   => $dest,
        error  => $!,
    ), 'Copy fail error message should be correct';
}
