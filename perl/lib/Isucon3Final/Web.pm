package Isucon3Final::Web;

use strict;
use warnings;
use utf8;

use File::Spec;
use File::Basename qw(dirname);
use Furl;
use Kossy;
use Digest::SHA qw/ sha256_hex /;
use DBIx::Sunny;
use JSON;
use JSON::Types;
use File::Temp qw/ tempfile /;
use POSIX qw/ floor /;
use File::Copy;
use Data::UUID;

use Imager;

my $APP_TMP_DIR = File::Spec->catfile(File::Spec->rel2abs(dirname __FILE__), "../../tmp");

our $TIMEOUT  = 30;
our $INTERVAL = 2;
our $UUID     = Data::UUID->new;

use constant {
    ICON_S   => 32,
    ICON_M   => 64,
    ICON_L   => 128,
    IMAGE_S  => 128,
    IMAGE_M  => 256,
    IMAGE_L  => undef,
};

my $FURL = Furl->new( ua => 'Isucon3Final::Web/Furl' );
sub furl { $FURL }

sub convert_with_crop {
    my $self = shift;
    my($orig, $ext, $crop_save, $w, $h, $save) = @_;
    if (-f $save) {
        open my $fh, '<', $save;
        local $/;
        return <$fh>;
    }

    $self->crop_square($orig, $ext, $crop_save);
    $self->convert($crop_save, $ext, $w, $h, $save);
}

sub convert_by_imagemagick {
    my $self = shift;
    my ($orig, $ext, $w, $h) = @_;
    my ($fh, $filename) = tempfile();
    my $newfile = "$filename.$ext";
    system("convert", "-geometry", "${w}x${h}", $orig, $newfile);
    open my $newfh, "<", $newfile or die $!;
    read $newfh, my $data, -s $newfile;
    close $newfh;
    unlink $newfile;
    unlink $filename;
    $data;
}

sub convert {
    my $self = shift;
    my ($orig, $ext, $w, $h, $save) = @_;
    if (-f $save) {
        open my $fh, '<', $save;
        local $/;
        return <$fh>;
    }

    my $type = $ext eq 'jpg' ? 'jpeg' : $ext;

    my $buffer;
    my $img = Imager->new(file => $orig, type => $type);
    unless (0 && $img) {
        $buffer = $self->convert_by_imagemagick(@_);
    } else {

        my $newimg = $img->scale(
            qtype => 'mixing',
            type => 'min',
            xpixels => $w,
            ypixels => $h,
        ) or die $img->errstr;

        $newimg->write(
            data => \$buffer,
            type => $type,
            jpegquality => 100,
        ) or die $img->errstr;
    }

    open my $fh, '>', $save;
    print $fh $buffer;
    close $fh;
    chmod 0644, $save;

    return $buffer;
}

sub _image_crop {
    my $self = shift;
    my ($img) = @_;
    my $w = $img->getwidth();
    my $h = $img->getheight();
    my ($crop_x, $crop_y, $pixels);
    if ( $w > $h ) {
        $pixels = $h;
        $crop_x = floor(($w - $pixels) / 2);
        $crop_y = 0;
    }
    elsif ( $w < $h ) {
        $pixels = $w;
        $crop_x = 0;
        $crop_y = floor(($h - $pixels) / 2);
    }
    else {
        $pixels = $w;
        $crop_x = 0;
        $crop_y = 0;
    }

    return $img->crop(
        width  => $pixels,
        height => $pixels,
        left   => $crop_x,
        top    => $crop_y,
    ) or die $img->errstr;
}

sub crop_square {
    my $self = shift;
    my ($orig, $ext, $save) = @_;
    return $save if -f $save; # has cache
    my $type = $ext eq 'jpg' ? 'jpeg' : $ext;
    my $img = Imager->new(file => $orig, type => $type)
        or die Imager->errstr;
    my $newimg = $self->_image_crop($img);
    $newimg->write(
        file => $save,
        type => $type,
        jpegquality => 100,
    ) or die $img->errstr;
    chmod 0644, $save;
    return $save;
}

sub load_config {
    my $self = shift;
    $self->{_config} ||= do {
        my $env = $ENV{ISUCON_ENV} || 'local';
        open(my $fh, '<', $self->root_dir . "/../config/${env}.json") or die $!;
        my $json = do { local $/; <$fh> };
        close($fh);
        decode_json($json);
    };
}

sub dbh {
    my ($self) = @_;
    $self->{_dbh} ||= do {
        my $dbconf = $self->load_config->{database};
        my @dsn = $dbconf->{dsn}
                ? @{ $dbconf->{dsn} }
                : (
                    "dbi:mysql:database=${$dbconf}{dbname};host=${$dbconf}{host};port=${$dbconf}{port}",
                    $dbconf->{username},
                    $dbconf->{password},
                );
        DBIx::Sunny->connect(
            @dsn, {
                RaiseError           => 1,
                PrintError           => 0,
                AutoInactiveDestroy  => 1,
                mysql_enable_utf8    => 1,
                mysql_auto_reconnect => 1,
            }
        );
    };
}

filter 'require_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        if (! $c->stash->{user}) {
            $c->halt(400);
        }
        $app->($self, $c);
    };
};

filter 'get_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $api_key = $c->req->headers->header("X-API-Key")
                   || $c->req->cookies->{api_key}
        ;
        my $user = $self->dbh->select_row(
            'SELECT * FROM users WHERE api_key=?',
            $api_key,
        );
        $c->stash->{user} = $user;
        $app->($self, $c);
    };
};

get '/' => sub {
    my ( $self, $c )  = @_;
    open my $fh, "<", "./public/index.html";
    my $html = do { local $/; <$fh> };
    $c->res->body($html);
};

post '/signup' => sub {
    my ( $self, $c ) = @_;
    my $name = $c->req->param("name");
    if ( $name !~ /\A[0-9a-zA-Z_]{2,16}\z/ ) {
        $c->halt(400);
    }
    my $api_key = sha256_hex( $UUID->create );
    $self->dbh->query(
        'INSERT INTO users (name, api_key, icon) VALUES (?, ?, ?)',
        $name, $api_key, 'default',
    );
    my $id = $self->dbh->last_insert_id;
    my $user = $self->dbh->select_row(
        'SELECT * FROM users WHERE id=?', $id,
    );
    $c->render_json({
        id      => number $user->{id},
        name    => $user->{name},
        icon    => $c->req->uri_for("/icon/" . $user->{icon}),
        api_key => $user->{api_key},
    });
};

get '/me' => [qw/ get_user require_user/] => sub {
    my ( $self, $c ) = @_;
    my $user = $c->stash->{user};
    $c->render_json({
        id   => number $user->{id},
        name => $user->{name},
        icon => $c->req->uri_for("/icon/" . $user->{icon}),
    });
};

get '/icon/:icon' => sub {
    my ( $self, $c ) = @_;
    my $icon = $c->args->{icon};
    my $size = $c->req->param("size") || "s";
    my $dir  = $self->load_config->{data_dir};
    if ( ! -e "$dir/icon/${icon}.png" ) {
        $c->halt(404);
    }
    my $w = $size eq "s" ? ICON_S
          : $size eq "m" ? ICON_M
          : $size eq "l" ? ICON_L
          :                ICON_S;
    my $h = $w;

    my $data = $self->convert("$dir/icon/${icon}.png", "png", $w, $h, "$dir/icon/${icon}-${w}x${h}.png");
    $c->res->content_type("image/png");
    $c->res->content( $data );
    $c->res;
};

post '/icon' => [qw/ get_user require_user /] => sub {
    my ( $self, $c ) = @_;
    my $user   = $c->stash->{user};
    my $upload = $c->req->uploads->{image};
    if (!$upload) {
        $c->halt(400);
    }
    if ( $upload->content_type !~ /^image\/(jpe?g|png)$/ ) {
        $c->halt(400);
    }

    my ($fh, $filename) = tempfile();
    my $icon = sha256_hex( $UUID->create );
    my $dir  = $self->load_config->{data_dir};
    $self->crop_square($upload->path, "png", "$dir/icon/$icon.png");

    $self->dbh->query(
        'UPDATE users SET icon=? WHERE id=?',
        $icon, $user->{id},
    );
    $c->render_json({
        icon => $c->req->uri_for("/icon/" . $icon),
    });
};

post '/entry' => [qw/ get_user require_user /] => sub {
    my ($self, $c) = @_;
    my $user   = $c->stash->{user};
    my $upload = $c->req->uploads->{image};
    if (!$upload) {
        $c->halt(400);
    }
    my $content_type = $upload->content_type;
    if ($content_type !~ /^image\/jpe?g/) {
        $c->halt(400);
    }
    my $image_id = sha256_hex( $UUID->create );
    my $dir = $self->load_config->{data_dir};
    File::Copy::move($upload->path, "$dir/image/$image_id.jpg")
        or $c->halt(500);
    chmod 0644, "$dir/image/$image_id.jpg";

    my $publish_level = $c->req->param("publish_level");
    $self->dbh->query(
        'INSERT INTO entries (user, image, publish_level, created_at) VALUES (?, ?, ?, now())',
        $user->{id}, $image_id, $publish_level,
    );
    my $id = $self->dbh->last_insert_id;
    my $entry = $self->dbh->select_row(
        'SELECT * FROM entries WHERE id=?', $id,
    );
    $c->render_json({
        id            => number $entry->{id},
        image         => $c->req->uri_for("/image/" . $entry->{image}),
        publish_level => number $entry->{publish_level},
        user => {
            id   => number $user->{id},
            name => $user->{name},
            icon => $c->req->uri_for("/icon/" . $user->{icon}),
        },
    });
};

post '/entry/:id' => [qw/ get_user require_user /] => sub {
    my ( $self, $c ) = @_;
    my $user  = $c->stash->{user};
    my $id    = $c->args->{id};
    my $dir   = $self->load_config->{data_dir};
    my $entry = $self->dbh->select_row("SELECT * FROM entries WHERE id=?", $id);
    if ( !$entry ) {
        $c->halt(404);
    }
    if ( $entry->{user} != $user->{id} || $c->req->param("__method") ne "DELETE" )
    {
        $c->halt(400);
    }
    $self->dbh->query("DELETE FROM entries WHERE id=?", $id);
    $c->render_json({
        ok => JSON::true,
    });
};

sub can_access_image {
    my ( $self, $c, $image, $user ) = @_;

    my $entry = $self->dbh->select_row(
        "SELECT * FROM entries WHERE image=?", $image,
    );
    if ( !$entry ) {
        $c->halt(404);
    }
    if ( $entry->{publish_level} == 0 ) {
        if ( $user && $entry->{user} == $user->{id} ) {
            # publish_level==0 はentryの所有者しか見えない
            # ok
        }
        else {
            $c->halt(404);
        }
    }
    elsif ( $entry->{publish_level} == 1 ) {
        # publish_level==1 はentryの所有者かfollowerしか見えない
        if ( ($entry->{user} || '') eq ($user->{id} || '') ) {
            # ok
        } else {
            my $follow = $self->dbh->select_row(
                "SELECT * FROM follow_map WHERE user=? AND target=?",
                $user->{id}, $entry->{user},
            );
            $c->halt(404) if !$follow;
        }
    }
}

sub get_image_data {
    my($self, $c, %args) = @_;

    my $want_file = $args{want_file};
    my $base_file = $args{base_file};

    if (-f $want_file) {
        # 欲しいファイルが手元にあるならそのまま返す
        open my $in, '<', $want_file or $c->halt(500);
        local $/;
        return <$in>;
    }

    if ($base_file && -f $base_file) {
        # オリジナルファイルがあれば、それを元にコンバートする
        return $self->convert_with_crop($base_file, 'jpg', $args{crop_save}, $args{w}, $args{h}, $want_file);
    }

    # 欲しいファイルの取得を試みる
    my $want_url = $want_file;
    $want_url =~ s{/home/isucon/webapp}{http://10.11.9.101};
    my $want_res = furl()->get($want_url);
    if ($want_res->is_success) {
        # 欲しいファイルあったので保存して返す
        open my $fh, '>', $want_file;
        print $fh $want_res->content;
        close $fh;
        chmod 0644, $want_file;
        return $want_res->content;
    }

    # オリジナルファイルの取得を試みる
    if ($base_file && -f $base_file) {
        my $base_url = $base_file;
        $base_url =~ s{/home/isucon/webapp}{http://10.11.9.101};
        my $base_res = furl()->get($base_url);
        if ($base_res->is_success) {
            # 欲しいファイルあったので保存して変換して返す
            open my $fh, '>', $base_file;
            print $fh $base_res->content;
            close $fh;
            chmod 0644, $base_file;

            return $self->convert_with_crop($base_file, 'jpg', $args{crop_save}, $args{w}, $args{h}, $want_file);
        }
    }

    die "cant find files want_file:$want_file base_file:$base_file";
}

get '/image/:image' => [qw/ get_user /] => sub {
    my ( $self, $c ) = @_;
    my $user  = $c->stash->{user};
    my $image = $c->args->{image};
    my $size  = $c->req->param("size") || "l";
    my $dir   = $self->load_config->{data_dir};
    my $local_dir = $self->load_config->{local_data_dir};

    $self->can_access_image($c, $image, $user);

    my $w = $size eq "s" ? IMAGE_S
          : $size eq "m" ? IMAGE_M
          : $size eq "l" ? IMAGE_L
          :                IMAGE_L;
    my $h = $w;
    my $data;
    if ($w) {
        my $_size = $size || 'l';
        $data = $self->get_image_data(
            $c,
            want_file => "$local_dir/image/${_size}/${image}-${w}x${h}.jpg",
            base_file => "$dir/image/${image}.jpg",
            crop_save => "$local_dir/image/${_size}/${image}.jpg",
            w         => $w,
            h         => $h,
        );
    }
    else {
        $data = $self->get_image_data(
            $c,
            want_file => "$dir/image/${image}.jpg",
        );
    }
    $c->res->content_type("image/jpeg");
    $c->res->content( $data );
    $c->res;
};

sub get_following {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};
    my $following = $self->dbh->select_all(
        "SELECT users.* FROM follow_map JOIN users ON (follow_map.target=users.id) WHERE follow_map.user = ? ORDER BY follow_map.created_at DESC",
        $user->{id},
    );
    $c->res->header("Cache-Control" => "no-cache");
    $c->render_json({
        users => [
            map {
                my $u = $_;
                +{
                    id   => number $u->{id},
                    name => $u->{name},
                    icon => $c->req->uri_for("/icon/" . $u->{icon}),
                };
            } @$following
        ],
    });
};

get '/follow' => [qw/ get_user require_user /] => \&get_following;

post '/follow' => [qw/ get_user require_user /] => sub {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};
    for my $target ( $c->req->param("target") ) {
        next if $target == $user->{id};
        $self->dbh->query(
            "INSERT IGNORE INTO follow_map (user, target, created_at) VALUES (?, ?, now())",
            $user->{id}, $target,
        );
    }
    get_following($self, $c);
};

post '/unfollow' => [qw/ get_user require_user /] => sub {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};
    for my $target ( $c->req->param("target") ) {
        next if $target == $user->{id};
        $self->dbh->query(
            "DELETE FROM follow_map WHERE user=? AND target=?",
            $user->{id}, $target,
        );
    }
    get_following($self, $c);
};

get '/timeline' => [qw/ get_user require_user /] => sub {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};
    my $latest_entry = $c->req->param("latest_entry");
    my ($sql, @params);
    if ($latest_entry) {
        $sql = 'SELECT * FROM (SELECT entries.*, u.name as user_name, u.icon as user_icon FROM entries INNER JOIN users as u ON entries.user = u.id WHERE (user=? OR publish_level=2 OR (publish_level=1 AND user IN (SELECT target FROM follow_map WHERE user=?))) AND entries.id > ? ORDER BY entries.id LIMIT 30) AS e ORDER BY e.id DESC';
        @params = ($user->{id}, $user->{id}, $latest_entry);
    }
    else {
        $sql = 'SELECT entries.*, u.name as user_name, u.icon as user_icon FROM entries INNER JOIN users as u ON entries.user = u.id WHERE (user=? OR publish_level=2 OR (publish_level=1 AND user IN (SELECT target FROM follow_map WHERE user=?))) ORDER BY entries.id DESC LIMIT 30';
        @params = ($user->{id}, $user->{id});
    }
    my $start = time;
    my @entries;
    while ( time - $start < $TIMEOUT ) {
        my $entries = $self->dbh->select_all($sql, @params);
        if (@$entries == 0) {
            sleep $INTERVAL;
            next;
        }
        else {
            @entries = @$entries;
            $latest_entry = $entries[0]->{id};
            last;
        }
    }
    $c->res->header("Cache-Control" => "no-cache");
    @entries = map {
        my $entry = $_;
        +{
            id         => number $entry->{id},
            image      => $c->req->uri_for("/image/" . $entry->{image}),
            publish_level => number $entry->{publish_level},
            user => {
                id   => number $entry->{user},
                name => $entry->{user_name},
                icon => $c->req->uri_for("/icon/" . $entry->{user_icon}),
            },
        }
    } @entries;
    $c->render_json({
        latest_entry => number $latest_entry,
        entries => \@entries,
    });
};


1;
