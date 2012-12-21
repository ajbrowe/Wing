package Wing::Rest;

use strict;
use warnings;
use Ouch;
use Dancer ':syntax';
use Dancer::Plugin;

set serializer => 'JSON';

require Wing::Dancer;

register get_session => sub {
    my (%options) = @_;
    my $session_id = $options{session_id} || params->{session_id};
    my $cookie = cookies->{session_id};
    if (!defined $session_id && defined $cookie) {
        $session_id = $cookie->value;
    }
    unless (defined $session_id) {
        ouch 441, 'session_id is required', 'session_id';
    }
    return $session_id if (ref $session_id eq 'Wing::Session');
    my $session = Wing::Session->new( id => $session_id, db => site_db() );
    if ($session->user_id) {
        $session->check_permissions($options{permissions});
        $session->extend;
        return $session;
    }
    else {
        ouch 451, 'Session expired.', $session_id;
    }
};

register get_user_by_session_id => sub {
    my $session = get_session(@_);
    return $session if (ref $session =~ m/DB::Result::User$/);
    my $user = $session->user;
    if (defined $user) {
        my $max = Wing->config->get('rpc_limit') || 30;
        if ($user->rpc_count > $max) {
            ouch 452, 'Slow down! You are only allowed to make ('.$max.') requests per minute to the server.', $max;
        }
        return $user;
    }
    return undef;
};

register describe => sub {
    my ($object, $current_user) = @_;
    $current_user ||= eval { get_user_by_session_id() };
    return $object->describe(
        include_private         => (eval { $object->can_use($current_user) }) ? 1 : 0,
        include_admin           => (eval { defined $current_user && $current_user->is_admin }) ? 1 : 0,
        include_relationships   => params->{_include_relationships},
        include_options         => params->{_include_options},
        include_related_objects => params->{_include_related_objects},
        current_user            => $current_user,
        tracer                  => get_tracer(),
    );
};

register generate_delete => sub {
    my ($wing_object_type, %options) = @_;
    my $object_url = lc($wing_object_type);
    del '/api/'.$object_url.'/:id'  => sub {
        my $object = fetch_object($wing_object_type);
        $object->can_use(get_user_by_session_id(permissions => $options{permissions}));
        $object->delete;
        return { success => 1 };
    };
};

register generate_update => sub {
    my ($wing_object_type, %options) = @_;
    my $object_url = lc($wing_object_type);
    put '/api/'.$object_url.'/:id'  => sub {
        my $current_user = get_user_by_session_id(permissions => $options{permissions});
        my $object = fetch_object($wing_object_type);
        $object->can_use($current_user);
        $object->verify_posted_params(expanded_params(), $current_user);
        if (exists $options{extra_processing}) {
            $options{extra_processing}->($object, $current_user);
        }
        $object->update;
        return describe($object, $current_user);
    };
};

register generate_create => sub {
    my ($wing_object_type, %options) = @_;
    my $object_url = lc($wing_object_type);
    post '/api/'.$object_url => sub {
        my $object = site_db()->resultset($wing_object_type)->new({});
        my $params = expanded_params();
        my $current_user = get_user_by_session_id(permissions => $options{permissions});
        $object->verify_creation_params($params, $current_user);
        $object->verify_posted_params($params, $current_user);
        if (defined $options{extra_processing}) {
            $options{extra_processing}->($object, $current_user);
        }
        $object->insert;
        return describe($object, $current_user);
    };
};

register generate_read => sub {
    my ($wing_object_type, %options) = @_;
    my $object_url = lc($wing_object_type);
    get '/api/'.$object_url.'/:id' => sub {
        my $current_user = eval{ get_user_by_session_id(permissions => $options{permissions}) };
        return describe(fetch_object($wing_object_type), $current_user);
    };
};

register generate_options => sub {
    my ($wing_object_type) = @_;
    my $object_url = lc($wing_object_type);
    get '/api/'.$object_url.'/_options' => sub {
        return site_db()->resultset($wing_object_type)->new({})->field_options(
            include_relationships   => params->{_include_relationships},
            include_options         => params->{_include_options},
            include_related_objects => params->{_include_related_objects},
            current_user            => eval { get_user_by_session_id() },
        );
    };
};

register generate_crud => sub {
    my ($wing_object_type) = @_;
    generate_options($wing_object_type);
    generate_read($wing_object_type);
    generate_update($wing_object_type);
    generate_delete($wing_object_type);
    generate_create($wing_object_type);
};

hook after => sub {
    my $response = shift;
    $response->content(to_json({ result => from_json($response->content) }));
    debug $response->content;
    return $response;
};

hook before_error_init => sub {
    my $error = shift;
    set show_errors => 1;
    if (ref $error->exception eq 'Ouch') {
        $error->{message} = {
            error   => $error->exception->hashref,
        };
        $error->{code} = $error->exception->code =~ m/^\d{3}$/ ? $error->exception->code : 500;
    }
    else {
        $error->{message} = {
            error   => {
                code    => 500,
                message => $error->message,
                data    => undef,
            }
        };
        $error->{code} = 500;
    }
    delete $error->{exception};
};

register_plugin;

1;
