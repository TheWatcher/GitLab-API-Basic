
package GitLab::API::Basic;

use REST::Client 0.273.1;
use Carp qw(croak carp);
use JSON;
use strict;

our $VERSION = '0.1.0';

# ============================================================================
#  Constructor


sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        url   => undef,
        token => undef,
        sudo  => undef,
        @_,
    };

    # Token and URL are required
    croak "GitLab::API::Basic: url not specified in call to new()" unless($self -> {"url"});
    croak "GitLab::API::Basic: token not provided in call to new()" unless($self -> {"token"});

    $self = bless $self, $class;

    # Build the REST client we wil issue requests through
    $self -> {"ua"} = REST::Client -> new( host      => $self -> {"url"},
                                           follow    => 1,
                                           useragent => LWP::UserAgent -> new(agent => "GitLab::API::Basic/$VERSION"))
        or croak "GitLab::API::Basic: unable to initialise REST::Client. This should not happen.";

    $self -> _set_headers();
    $self -> _set_api();

    return $self;
}

# ============================================================================
#  Common interface

## @method void sudo($user)
# The GitLab API allows calls made with an administrator token to be performed
# as a different user. This function allows that user to be specified. Note that
# attempting to sudo when not using an administrator token will cause all API
# calls to fail with '403 Forbidden' errors.
#
# @param user The ID or username of the user to perform operations as. If set
#             to undef or an empty string, the sudo is cleared.
sub sudo {
    my $self = shift;
    my $user = shift;

    $self -> {"sudo"} = $user ? $user : undef;
    $self -> _set_headers();
}


## @method get_project_id($namespace, $project)
# Given a user and a project name, this will attempt to determine the ID
# of the project it corresponds do. Note that this can only effectively be
# called by an admin, unless the username specified matches the user the
# token belongs to.
#
# @param user The username of the user who



## @method $ call($operation, $method, $parameters)
#
sub call {
    my $self       = shift;
    my $operation  = lc(shift);
    my $method     = uc(shift);
    my $parameters = shift;

    $self -> clear_error();

    # Look up the operation information
    my $opdesc = $self -> {"_api"} -> {$operation} -> {$method}
        if($operation && $method);

    # Determine whether the specified method and operation are valid
    return $self -> self_error("Attempt to perform '$method' of operation '$operation': bad method/operation specified")
        unless($opdesc);

    # Check through the parameters, copying known parameters into this hash...
    my $useparams = {};

    # First handle the required parameters, complain if a required param is missing
    foreach my $param (keys %{$opdesc -> {"params"} -> {"required"}}) {
        return $self -> self_error("$operation called without required parameter '$param'")
            unless($parameters -> {$param});

        $useparams -> {$param} = $parameters -> {$param};
    }

    # next handle optionals
    foreach my $param (keys %{$opdesc -> {"params"} -> {"optional"}}) {
        $useparams -> {$param} = $parameters -> {$param}
            if($parameters -> {$param});
    }

    # replace URL params
    my @markers = $operation =~ m{\:(\w+)(?:$|/)}g;
    # Sort names in descending length order to prevent shorter markers
    # inadvertently matching parts of longer ones and opening the dread
    # gates of carcosa.
    foreach my $marker (sort { length($b) <=> length($a) } @markers) {
        return $self -> self_error("Unable to locate value for URL-required param ':$marker'")
            unless($useparams -> {$marker});

        $operation =~ s/:$marker/$useparams->{$marker}/;

        # Remove the parameter from the used params, as it should no longer be passed in
        # via the query string/post body/etc
        delete $useparams -> {$marker};
    }

    # Work out the query and body
    my ($query_string, $body_content, $headers) = $self -> _build_parameters($method, $useparams);

    # build the URL
    my $url = $self -> _path_join("api/v3", $operation);
    $url .= "?$query_string" if($query_string);

    # Note that important headers are set globally, but $headers may
    # contain incantations indicating the body is x-www-form-urlencoded
    $self -> {"ua"} -> request($method, $url, $body_content, $headers);

    # did the response succeed?
    if($self -> {"ua"} -> responseCode =~ /^2\d\d$/) {
        return { "status" => "success" }
            if(!$self -> {"ua"} -> responseContent()); # successful response with no body is okay

        my $json = eval { decode_json($self -> {"ua"} -> responseContent()) };
        return $self -> self_error("Request succeeded, bur JSON parsing failed: $@")
            if($@);

        return $json;
    }

    # For some reason REST::Client doesn't expose the status line from the result.
    # Thankfully, we can go into the result directly.
    return $self -> self_error("Request failed. Response was: ".$self -> {"ua"} -> {_res} -> status_line);
}


# ============================================================================
#  Error functions


## @method private $ self_error($errstr)
# Set the object's errstr value to an error message, and return undef. This
# function supports error reporting in various methods throughout the class.
#
# @param errstr The error message to store in the object's errstr.
# @return Always returns undef.
sub self_error {
    my $self = shift;
    $self -> {"errstr"} = shift;

    return undef;
}


## @method private void clear_error()
# Clear the object's errstr value. This is a convenience function to help
# make the code a bit cleaner.
sub clear_error {
    my $self = shift;

    $self -> self_error(undef);
}


## @method $ errstr()
# Return the current value set in the object's errstr value. This is a
# convenience function to help make code a little cleaner.
sub errstr {
    my $self = shift;

    return $self -> {"errstr"};
}


# ============================================================================
#  Things mankind was not meant to know...

## @method private $ _path_join(@fragments)
# Take an array of path fragments and concatenate them together. This will
# concatenate the list of path fragments provided using '/' as the path
# delimiter (this is not as platform specific as might be imagined: windows
# will accept / delimited paths). The resuling string is trimmed so that it
# <b>does not</b> end in /, but nothing is done to ensure that the string
# returned actually contains a valid path.
#
# @param fragments An array of path fragments to join together. Items in the
#                  array that are undef or "" are skipped.
# @return A string containing the path fragments joined with forward slashes.
sub _path_join {
    my $path      = shift;
    my @fragments = @_;
    my $leadslash;

    # strip leading and trailing slashes from fragments
    my @parts;
    foreach my $bit (@fragments) {
        # Skip empty fragments.
        next if(!defined($bit) || $bit eq "");

        # Determine whether the first real path has a leading slash.
        $leadslash = $bit =~ m|^/| unless(defined($leadslash));

        # Remove leading and trailing slashes
        $bit =~ s|^/*||; $bit =~ s|/*$||;

        # If the fragment was nothing more than slashes, ignore it
        next unless($bit);

        # Store for joining
        push(@parts, $bit);
    }

    # Join the path, possibly including a leading slash if needed
    return ($leadslash ? "/" : "").join("/", @parts);
}


## @method private void _set_headers(void)
# Update the custom headers set in the REST::Client to reflect the current token
# and sudo settings.
#
sub _set_headers {
    my $self = shift;

    croak "GitLab::API::Basic: call to _set_headers() with no valid REST::Client available."
        unless($self -> {"ua"});

    $self -> {"ua"} -> addHeader('PRIVATE-TOKEN', $self -> {"token"});

    if($self -> {"sudo"}) {
        $self -> {"ua"} -> addHeader('SUDO', $self -> {"sudo"});
    } else {
        $self -> {"ua"} -> deleteHeader('SUDO');
    }
}


## @method private @ _build_parameters($method, $params)
# Generate the query string, body content, and extra headers based on the
# specified method and parameters hash.
#
# @param method The HTTP method the request will use.
# @param params A reference to a hash of parameters the request will include.
# @return An array of three values: the query string fragment without leading
#         ?, the body content, and a reference to a hash containing extra
#         headers. Note that any (or all three!) of these may be undef depending
#         on the method and parameters.
sub _build_parameters {
    my $self   = shift;
    my $method = shift;
    my $params = shift;

    # If there are no parameters, there's nothing to do anyway
    return (undef, undef, undef)
        unless(scalar(keys(%{$params})));

    # buildQuery includes the ?, which we aren't interested in here, so drop it.
    my $outparam = substr($self -> {"ua"} -> buildQuery($params), 1);

    # If the method is anything other than a GET the message body must be encoded.
    # For GET there is no message body, so the header can be undef.
    if($method eq "GET") {
        return ($outparam, undef, undef);
    } else {
        return (undef, $outparam, { 'Content-type' => 'application/x-www-form-urlencoded' });
    }
}


## @method private void _set_api(void)
# Set up the information about the API. This is needed to allow
# the call() function to validate and build API calls.
#
sub _set_api {
    my $self = shift;

    $self -> {"_api"} = {
        "/application/settings" => {
            "GET" => {
                "title" => "Get current application settings:",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "after_sign_out_path" => "where redirect user after logout",
                        "default_branch_protection" => "determine if developers can push to master",
                        "default_project_visibility" => "what visibility level new project receives",
                        "default_projects_limit" => "project limit per user",
                        "default_snippet_visibility" => "what visibility level new snippet receives",
                        "gravatar_enabled" => "enable gravatar",
                        "home_page_url" => "redirect to this URL when not logged in",
                        "max_attachment_size" => "limit attachment size",
                        "restricted_signup_domains" => "force people to use only corporate emails for signup",
                        "restricted_visibility_levels" => "restrict certain visibility levels",
                        "sign_in_text" => "text on login page",
                        "signin_enabled" => "enable login via GitLab account",
                        "signup_enabled" => "enable registration",
                        "twitter_sharing_enabled" => "allow users to share project creation in twitter",
                        "user_oauth_applications" => "allow users to create oauth applicaitons",
                    }
                },
                "title" => "Change application settings:",
            }
        },
        "/groups" => {
            "GET" => {
                "title" => "List project groups",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "description" => "The group's description",
                    },
                    "required" => {
                        "name" => "The name of the group",
                        "path" => "The path of the group",
                    }
                },
                "title" => "New group",
            }
        },
        "/groups/:id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID or path of a user group",
                    }
                },
                "title" => "Remove group",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID or path of a group",
                    }
                },
                "title" => "Details of a group",
            }
        },
        "/groups/:id/members" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID or path of a group",
                    }
                },
                "title" => "List group members",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "access_level" => "Project access level",
                        "id" => "The ID or path of a group",
                        "user_id" => "The ID of a user to add",
                    }
                },
                "title" => "Add group member",
            }
        },
        "/groups/:id/members/:user_id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID or path of a user group",
                        "user_id" => "The ID of a group member",
                    }
                },
                "title" => "Remove user team member",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "access_level" => "Project access level",
                        "id" => "The ID of a group",
                        "user_id" => "The ID of a group member",
                    }
                },
                "title" => "Edit group team member",
            }
        },
        "/groups/:id/projects/:project_id" => {
            "POST" => {
                "params" => {
                    "required" => {
                        "id" => "The ID or path of a group",
                        "project_id" => "The ID of a project",
                    }
                },
                "title" => "Transfer project to group",
            }
        },
        "/groups?search=foobar" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "search" => "The string to match in the name or path",
                    }
                },
                "title" => "Search for group",
            }
        },
        "/hooks" => {
            "GET" => {
                "title" => "List system hooks",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "url" => "The hook URL",
                    }
                },
                "title" => "Add new system hook hook",
            }
        },
        "/hooks/:id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of hook",
                    }
                },
                "title" => "Delete system hook",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of hook",
                    }
                },
                "title" => "Test system hook",
            }
        },
        "/issues" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "labels" => "Comma-separated list of label names",
                        "order_by" => "Return requests ordered by `created_at` or `updated_at` fields. Default is `created_at`",
                        "sort" => "Return requests sorted in `asc` or `desc` order. Default is `desc`",
                        "state" => "Return `all` issues or just those that are `opened` or `closed`",
                    }
                },
                "title" => "List issues",
            }
        },
        "/keys/:id" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of an SSH key",
                    }
                },
                "title" => "Get SSH key with user by ID of an SSH key",
            }
        },
        "/namespaces" => {
            "GET" => {
                "title" => "List namespaces",
            }
        },
        "/namespaces?search=foobar" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "search" => "The string to search for.",
                    }
                },
                "title" => "Search for namespace",
            }
        },
        "/projects" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "archived" => "if passed, limit by archived status",
                        "ci_enabled_first" => "Return projects ordered by ci_enabled flag. Projects with enabled GitLab CI go first",
                        "order_by" => "Return requests ordered by `id`, `name`, `path`, `created_at`, `updated_at` or `last_activity_at` fields. Default is `created_at`",
                        "search" => "Return list of authorized projects according to a search criteria",
                        "sort" => "Return requests sorted in `asc` or `desc` order. Default is `desc`",
                    }
                },
                "title" => "List projects",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "description" => "short project description",
                        "issues_enabled" => "`merge_requests_enabled` (optional)",
                        "namespace_id" => "namespace for the new project (defaults to user)",
                        "path" => "custom repository name for new project. By default generated based on name",
                        "public" => "if `true` same as setting visibility_level = 20",
                        "visibility_level" => "`import_url` (optional)",
                        "wiki_enabled" => "`snippets_enabled` (optional)",
                    },
                    "required" => {
                        "name" => "new project name",
                    }
                },
                "title" => "Create project",
            }
        },
        "/projects/:id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Remove project",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Get single project",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "default_branch" => "`issues_enabled` (optional)",
                        "description" => "short project description",
                        "merge_requests_enabled" => "`wiki_enabled` (optional)",
                        "name" => "project name",
                        "path" => "repository name for project",
                        "snippets_enabled" => "`public` (optional) - if `true` same as setting visibility_level = 20",
                        "visibility_level" => "",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Edit project",
            }
        },
        "/projects/:id/events" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Get project events",
            }
        },
        "/projects/:id/fork" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of the project",
                    }
                },
                "title" => "Delete an existing forked from relationship",
            }
        },
        "/projects/:id/fork/:forked_from_id" => {
            "POST" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of the project",
                        "forked_from_id" => "The ID of the project the project was forked from",
                    }
                },
                "title" => "Create a forked from/to relation between existing projects.",
            }
        },
        "/projects/:id/hooks" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List project hooks",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "issues_events" => "Trigger hook on issues events",
                        "merge_requests_events" => "Trigger hook on merge_requests events",
                        "push_events" => "Trigger hook on push events",
                        "tag_push_events" => "Trigger hook on push_tag events",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "url" => "The hook URL",
                    }
                },
                "title" => "Add project hook",
            }
        },
        "/projects/:id/hooks/:hook_id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "hook_id" => "The ID of hook to delete",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete project hook",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "hook_id" => "The ID of a project hook",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Get project hook",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "issues_events" => "Trigger hook on issues events",
                        "merge_requests_events" => "Trigger hook on merge_requests events",
                        "push_events" => "Trigger hook on push events",
                        "tag_push_events" => "Trigger hook on push_tag events",
                    },
                    "required" => {
                        "hook_id" => "The ID of a project hook",
                        "id" => "The ID of a project",
                        "url" => "The hook URL",
                    }
                },
                "title" => "Edit project hook",
            }
        },
        "/projects/:id/issues" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "iid" => "Return the issue having the given `iid`",
                        "labels" => "Comma-separated list of label names",
                        "milestone" => "Milestone title",
                        "order_by" => "Return requests ordered by `created_at` or `updated_at` fields. Default is `created_at`",
                        "sort" => "Return requests sorted in `asc` or `desc` order. Default is `desc`",
                        "state" => "Return `all` issues or just those that are `opened` or `closed`",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List project issues",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "assignee_id" => "The ID of a user to assign issue",
                        "description" => "The description of an issue",
                        "labels" => "Comma-separated label names for an issue",
                        "milestone_id" => "The ID of a milestone to assign issue",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "title" => "The title of an issue",
                    }
                },
                "title" => "New issue",
            }
        },
        "/projects/:id/issues/:issue_id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The project ID",
                        "issue_id" => "The ID of the issue",
                    }
                },
                "title" => "Delete existing issue (**Deprecated**)",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "issue_id" => "The ID of a project issue",
                    }
                },
                "title" => "Single issue",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "assignee_id" => "The ID of a user to assign issue",
                        "description" => "The description of an issue",
                        "labels" => "Comma-separated label names for an issue",
                        "milestone_id" => "The ID of a milestone to assign issue",
                        "state_event" => "The state event of an issue ('close' to close issue and 'reopen' to reopen it)",
                        "title" => "The title of an issue",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "issue_id" => "The ID of a project's issue",
                    }
                },
                "title" => "Edit issue",
            }
        },
        "/projects/:id/issues/:issue_id/notes" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "issue_id" => "The ID of an issue",
                    }
                },
                "title" => "List project issue notes",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "body" => "The content of a note",
                        "id" => "The ID of a project",
                        "issue_id" => "The ID of an issue",
                    }
                },
                "title" => "Create new issue note",
            }
        },
        "/projects/:id/issues/:issue_id/notes/:note_id" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "issue_id" => "The ID of a project issue",
                        "note_id" => "The ID of an issue note",
                    }
                },
                "title" => "Get single issue note",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "body" => "The content of a note",
                        "id" => "The ID of a project",
                        "issue_id" => "The ID of an issue",
                        "note_id" => "The ID of a note",
                    }
                },
                "title" => "Modify existing issue note",
            }
        },
        "/projects/:id/keys" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of the project",
                    }
                },
                "title" => "List deploy keys",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of the project",
                        "key" => "New deploy key",
                        "title" => "New deploy key's title",
                    }
                },
                "title" => "Add deploy key",
            }
        },
        "/projects/:id/keys/:key_id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of the project",
                        "key_id" => "The ID of the deploy key",
                    }
                },
                "title" => "Delete deploy key",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of the project",
                        "key_id" => "The ID of the deploy key",
                    }
                },
                "title" => "Single deploy key",
            }
        },
        "/projects/:id/labels" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "name" => "The name of the label to be deleted",
                    }
                },
                "title" => "Delete a label",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List labels",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "color" => " Color of the label given in 6-digit hex notation with leading '#' sign (e.g. #FFAABB)",
                        "id" => "The ID of a project",
                        "name" => "The name of the label",
                    }
                },
                "title" => "Create a new label",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "color" => " New color of the label given in 6-digit hex notation with leading '#' sign (e.g. #FFAABB)",
                        "new_name" => "The new name of the label",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "name" => "The name of the existing label",
                    }
                },
                "title" => "Edit an existing label",
            }
        },
        "/projects/:id/members" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "query" => "Query string to search for members",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List project team members",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "access_level" => "Project access level",
                        "id" => "The ID of a project",
                        "user_id" => "The ID of a user to add",
                    }
                },
                "title" => "Add project team member",
            }
        },
        "/projects/:id/members/:user_id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "user_id" => "The ID of a team member",
                    }
                },
                "title" => "Remove project team member",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "user_id" => "The ID of a user",
                    }
                },
                "title" => "Get project team member",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "access_level" => "Project access level",
                        "id" => "The ID of a project",
                        "user_id" => "The ID of a team member",
                    }
                },
                "title" => "Edit project team member",
            }
        },
        "/projects/:id/merge_request/:merge_request_id" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "merge_request_id" => "The ID of MR",
                    }
                },
                "title" => "Get single MR",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "merge_request_id" => "ID of MR",
                    }
                },
                "title" => "Update MR",
            }
        },
        "/projects/:id/merge_request/:merge_request_id/changes" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "merge_request_id" => "The ID of MR",
                    }
                },
                "title" => "Get single MR changes",
            }
        },
        "/projects/:id/merge_request/:merge_request_id/comments" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "merge_request_id" => "ID of merge request",
                    }
                },
                "title" => "Get the comments on a MR",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "merge_request_id" => "ID of merge request",
                        "note" => "Text of comment",
                    }
                },
                "title" => "Post comment to MR",
            }
        },
        "/projects/:id/merge_request/:merge_request_id/merge" => {
            "PUT" => {
                "params" => {
                    "optional" => {
                        "merge_commit_message" => "Custom merge commit message",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "merge_request_id" => "ID of MR",
                    }
                },
                "title" => "Accept MR",
            }
        },
        "/projects/:id/merge_requests" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "iid" => "Return the request having the given `iid`",
                        "order_by" => "Return requests ordered by `created_at` or `updated_at` fields. Default is `created_at`",
                        "sort" => "Return requests sorted in `asc` or `desc` order. Default is `desc`",
                        "state" => "Return `all` requests or just those that are `merged`, `opened` or `closed`",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List merge requests",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "assignee_id" => "Assignee user ID",
                        "description" => "Description of MR",
                        "target_project_id" => "The target project (numeric id)",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "source_branch" => "The source branch",
                        "target_branch" => "The target branch",
                        "title" => "Title of MR",
                    }
                },
                "title" => "Create MR",
            }
        },
        "/projects/:id/merge_requests/:merge_request_id/notes" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "merge_request_id" => "The ID of a project merge request",
                    }
                },
                "title" => "List all merge request notes",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "body" => "The content of a note",
                        "id" => "The ID of a project",
                        "merge_request_id" => "The ID of a merge request",
                    }
                },
                "title" => "Create new merge request note",
            }
        },
        "/projects/:id/merge_requests/:merge_request_id/notes/:note_id" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "merge_request_id" => "The ID of a project merge request",
                        "note_id" => "The ID of a merge request note",
                    }
                },
                "title" => "Get single merge request note",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "body" => "The content of a note",
                        "id" => "The ID of a project",
                        "merge_request_id" => "The ID of a merge request",
                        "note_id" => "The ID of a note",
                    }
                },
                "title" => "Modify existing merge request note",
            }
        },
        "/projects/:id/milestones" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "iid" => "Return the milestone having the given `iid`",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List project milestones",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "description" => "The description of the milestone",
                        "due_date" => "The due date of the milestone",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "title" => "The title of an milestone",
                    }
                },
                "title" => "Create new milestone",
            }
        },
        "/projects/:id/milestones/:milestone_id" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "milestone_id" => "The ID of a project milestone",
                    }
                },
                "title" => "Get single milestone",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "description" => "The description of a milestone",
                        "due_date" => "The due date of the milestone",
                        "state_event" => "The state event of the milestone (close|activate)",
                        "title" => "The title of a milestone",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "milestone_id" => "The ID of a project milestone",
                    }
                },
                "title" => "Edit milestone",
            }
        },
        "/projects/:id/milestones/:milestone_id/issues" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "milestone_id" => "The ID of a project milestone",
                    }
                },
                "title" => "Get all issues assigned to a single milestone",
            }
        },
        "/projects/:id/repository/archive" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "sha" => "The commit SHA to download defaults to the tip of the default branch",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Get file archive",
            }
        },
        "/projects/:id/repository/blobs/:sha" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "filepath" => "The path the file",
                        "id" => "The ID of a project",
                        "sha" => "The commit or branch name",
                    }
                },
                "title" => "Raw file content",
            }
        },
        "/projects/:id/repository/branches" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List branches",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "branch_name" => "The name of the branch",
                        "id" => "The ID of a project",
                        "ref" => "Create branch from commit SHA or existing branch",
                    }
                },
                "title" => "Create repository branch",
            }
        },
        "/projects/:id/repository/branches/:branch" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "branch" => "The name of the branch",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete repository branch",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "branch" => "The name of the branch.",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List single branch",
            }
        },
        "/projects/:id/repository/branches/:branch/protect" => {
            "PUT" => {
                "params" => {
                    "required" => {
                        "branch" => "The name of the branch.",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Protect single branch",
            }
        },
        "/projects/:id/repository/branches/:branch/unprotect" => {
            "PUT" => {
                "params" => {
                    "required" => {
                        "branch" => "The name of the branch.",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Unprotect single branch",
            }
        },
        "/projects/:id/repository/commits" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "ref_name" => "The name of a repository branch or tag or if not given the default branch",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List repository commits",
            }
        },
        "/projects/:id/repository/commits/:sha" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "sha" => "The commit hash or name of a repository branch or tag",
                    }
                },
                "title" => "Get a single commit",
            }
        },
        "/projects/:id/repository/commits/:sha/comments" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "sha" => "The name of a repository branch or tag or if not given the default branch",
                    }
                },
                "title" => "Get the comments of a commit",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "line" => "The line number",
                        "line_type" => "The line type (new or old)",
                        "path" => "The file path",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "note" => "Text of comment",
                        "sha" => "The name of a repository branch or tag or if not given the default branch",
                    }
                },
                "title" => "Post comment to commit",
            }
        },
        "/projects/:id/repository/commits/:sha/diff" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "sha" => "The name of a repository branch or tag or if not given the default branch",
                    }
                },
                "title" => "Get the diff of a commit",
            }
        },
        "/projects/:id/repository/compare" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "from" => "the commit SHA or branch name",
                        "id" => "The ID of a project",
                        "to" => "the commit SHA or branch name",
                    }
                },
                "title" => "Compare branches, tags or commits",
            }
        },
        "/projects/:id/repository/contributors" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Contributors",
            }
        },
        "/projects/:id/repository/files" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "branch_name" => "The name of branch",
                        "commit_message" => "Commit message",
                        "file_path" => "Full path to file. Ex. lib/class.rb",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete existing file in repository",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "file_path" => "Full path to new file. Ex. lib/class.rb",
                        "id" => "The ID of a project",
                        "ref" => "The name of branch, tag or commit",
                    }
                },
                "title" => "Get file from repository",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "encoding" => "'text' or 'base64'. Text is default.",
                    },
                    "required" => {
                        "branch_name" => "The name of branch",
                        "commit_message" => "Commit message",
                        "content" => "File content",
                        "file_path" => "Full path to new file. Ex. lib/class.rb",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Create new file in repository",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "encoding" => "'text' or 'base64'. Text is default.",
                    },
                    "required" => {
                        "branch_name" => "The name of branch",
                        "commit_message" => "Commit message",
                        "content" => "New file content",
                        "file_path" => "Full path to file. Ex. lib/class.rb",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Update existing file in repository",
            }
        },
        "/projects/:id/repository/raw_blobs/:sha" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "sha" => "The blob SHA",
                    }
                },
                "title" => "Raw blob content",
            }
        },
        "/projects/:id/repository/tags" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List project repository tags",
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "message" => "Creates annotated tag.",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "ref" => "Create tag using commit SHA, another tag name, or branch name.",
                        "tag_name" => "The name of a tag",
                    }
                },
                "title" => "Create a new tag",
            }
        },
        "/projects/:id/repository/tree" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "path" => "The path inside repository. Used to get contend of subdirectories",
                        "ref_name" => "The name of a repository branch or tag or if not given the default branch",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List repository tree",
            }
        },
        "/projects/:id/services/asana" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Asana service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "restrict_to_branch" => "Comma-separated list of branches which will beautomatically inspected. Leave blank to include all branches.",
                    },
                    "required" => {
                        "api_key" => "User API token. User must have access to task,all comments will be attributed to this user.",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Create/Edit Asana service",
            }
        },
        "/projects/:id/services/assembla" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Assembla service",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "token" => "`subdomain` (optional)",
                    }
                },
                "title" => "Create/Edit Assembla service",
            }
        },
        "/projects/:id/services/bamboo" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Atlassian Bamboo CI service",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "bamboo_url" => "Bamboo root URL like https://bamboo.example.com",
                        "build_key" => "Bamboo build plan key like KEY",
                        "id" => "The ID of a project",
                        "password" => "",
                        "username" => "A user with API access, if applicable",
                    }
                },
                "title" => "Create/Edit Atlassian Bamboo CI service",
            }
        },
        "/projects/:id/services/buildkite" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Buildkite service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "enable_ssl_verification" => "Enable SSL verification",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "project_url" => "https://buildkite.com/example/project",
                        "token" => "Buildkite project GitLab token",
                    }
                },
                "title" => "Create/Edit Buildkite service",
            }
        },
        "/projects/:id/services/campfire" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Campfire service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "room" => "",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "token" => "`subdomain` (optional)",
                    }
                },
                "title" => "Create/Edit Campfire service",
            }
        },
        "/projects/:id/services/custom-issue-tracker" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Custom Issue Tracker service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "description" => "Custom issue tracker",
                        "title" => "Custom Issue Tracker",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "issues_url" => "Issue url",
                        "new_issue_url" => "New Issue url",
                        "project_url" => "Project url",
                    }
                },
                "title" => "Create/Edit Custom Issue Tracker service",
            }
        },
        "/projects/:id/services/drone-ci" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Drone CI service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "enable_ssl_verification" => "Enable SSL verification",
                    },
                    "required" => {
                        "drone_url" => "http://drone.example.com",
                        "id" => "The ID of a project",
                        "token" => "Drone CI project specific token",
                    }
                },
                "title" => "Create/Edit Drone CI service",
            }
        },
        "/projects/:id/services/emails-on-push" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Emails on push service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "disable_diffs" => "Disable code diffs",
                        "send_from_committer_email" => "Send from committer",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "recipients" => "Emails separated by whitespace",
                    }
                },
                "title" => "Create/Edit Emails on push service",
            }
        },
        "/projects/:id/services/external-wiki" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete External Wiki service",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "external_wiki_url" => "The URL of the external Wiki",
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Create/Edit External Wiki service",
            }
        },
        "/projects/:id/services/flowdock" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Flowdock service",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "token" => "Flowdock Git source token",
                    }
                },
                "title" => "Create/Edit Flowdock service",
            }
        },
        "/projects/:id/services/gemnasium" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Gemnasium service",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "api_key" => "Your personal API KEY on gemnasium.com",
                        "id" => "The ID of a project",
                        "token" => "The project's slug on gemnasium.com",
                    }
                },
                "title" => "Create/Edit Gemnasium service",
            }
        },
        "/projects/:id/services/gitlab-ci" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete GitLab CI service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "enable_ssl_verification" => "Enable SSL verification",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "project_url" => "http://ci.gitlabhq.com/projects/3",
                        "token" => "GitLab CI project specific token",
                    }
                },
                "title" => "Create/Edit GitLab CI service",
            }
        },
        "/projects/:id/services/hipchat" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete HipChat service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "api_version" => "Leave blank for default (v2)",
                        "color" => "`notify` (optional)",
                        "room" => "Room name or ID",
                        "server" => "Leave blank for default. https://hipchat.example.com",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "token" => "Room token",
                    }
                },
                "title" => "Create/Edit HipChat service",
            }
        },
        "/projects/:id/services/irker" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Irker (IRC gateway) service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "colorize_messages" => "",
                        "default_irc_uri" => "irc://irc.network.net:6697/",
                        "server_host" => "localhost",
                        "server_port" => "6659",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "recipients" => "Recipients/channels separated by whitespaces",
                    }
                },
                "title" => "Create/Edit Irker (IRC gateway) service",
            }
        },
        "/projects/:id/services/jira" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete JIRA service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "description" => "Jira issue tracker",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "issues_url" => "Issue url",
                        "new_issue_url" => "New Issue url",
                        "project_url" => "Project url",
                    }
                },
                "title" => "Create/Edit JIRA service",
            }
        },
        "/projects/:id/services/pivotaltracker" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete PivotalTracker service",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "token" => "",
                    }
                },
                "title" => "Create/Edit PivotalTracker service",
            }
        },
        "/projects/:id/services/pushover" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Pushover service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "sound" => "",
                    },
                    "required" => {
                        "api_key" => "Your application key",
                        "id" => "The ID of a project",
                        "priority" => "`device` (optional) - Leave blank for all active devices",
                        "user_key" => "Your user key",
                    }
                },
                "title" => "Create/Edit Pushover service",
            }
        },
        "/projects/:id/services/redmine" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Redmine service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "description" => "Redmine issue tracker",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "issues_url" => "Issue url",
                        "new_issue_url" => "New Issue url",
                        "project_url" => "Project url",
                    }
                },
                "title" => "Create/Edit Redmine service",
            }
        },
        "/projects/:id/services/slack" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete Slack service",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "channel" => "#channel",
                        "username" => "username",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "webhook" => "https://hooks.slack.com/services/...",
                    }
                },
                "title" => "Create/Edit Slack service",
            }
        },
        "/projects/:id/services/teamcity" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "Delete JetBrains TeamCity CI service",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "build_type" => "Build configuration ID",
                        "id" => "The ID of a project",
                        "password" => "",
                        "teamcity_url" => "TeamCity root URL like https://teamcity.example.com",
                        "username" => "A user with permissions to trigger a manual build",
                    }
                },
                "title" => "Create/Edit JetBrains TeamCity CI service",
            }
        },
        "/projects/:id/snippets" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                    }
                },
                "title" => "List snippets",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "code" => "The content of a snippet",
                        "file_name" => "The name of a snippet file",
                        "id" => "The ID of a project",
                        "title" => "The title of a snippet",
                        "visibility_level" => "The snippet's visibility",
                    }
                },
                "title" => "Create new snippet",
            }
        },
        "/projects/:id/snippets/:snippet_id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "snippet_id" => "The ID of a project's snippet",
                    }
                },
                "title" => "Delete snippet",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "snippet_id" => "The ID of a project's snippet",
                    }
                },
                "title" => "Single snippet",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "code" => "The content of a snippet",
                        "file_name" => "The name of a snippet file",
                        "title" => "The title of a snippet",
                        "visibility_level" => "The snippet's visibility",
                    },
                    "required" => {
                        "id" => "The ID of a project",
                        "snippet_id" => "The ID of a project's snippet",
                    }
                },
                "title" => "Update snippet",
            }
        },
        "/projects/:id/snippets/:snippet_id/notes" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "snippet_id" => "The ID of a project snippet",
                    }
                },
                "title" => "List all snippet notes",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "body" => "The content of a note",
                        "id" => "The ID of a project",
                        "snippet_id" => "The ID of a snippet",
                    }
                },
                "title" => "Create new snippet note",
            }
        },
        "/projects/:id/snippets/:snippet_id/notes/:note_id" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "note_id" => "The ID of an snippet note",
                        "snippet_id" => "The ID of a project snippet",
                    }
                },
                "title" => "Get single snippet note",
            },
            "PUT" => {
                "params" => {
                    "required" => {
                        "body" => "The content of a note",
                        "id" => "The ID of a project",
                        "note_id" => "The ID of a note",
                        "snippet_id" => "The ID of a snippet",
                    }
                },
                "title" => "Modify existing snippet note",
            }
        },
        "/projects/:id/snippets/:snippet_id/raw" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a project",
                        "snippet_id" => "The ID of a project's snippet",
                    }
                },
                "title" => "Snippet content",
            }
        },
        "/projects/all" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "archived" => "if passed, limit by archived status",
                        "ci_enabled_first" => "Return projects ordered by ci_enabled flag. Projects with enabled GitLab CI go first",
                        "order_by" => "Return requests ordered by `id`, `name`, `path`, `created_at`, `updated_at` or `last_activity_at` fields. Default is `created_at`",
                        "search" => "Return list of authorized projects according to a search criteria",
                        "sort" => "Return requests sorted in `asc` or `desc` order. Default is `desc`",
                    }
                },
                "title" => "List ALL projects",
            }
        },
        "/projects/fork/:id" => {
            "POST" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of the project to be forked",
                    }
                },
                "title" => "Fork project",
            }
        },
        "/projects/owned" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "archived" => "if passed, limit by archived status",
                        "ci_enabled_first" => "Return projects ordered by ci_enabled flag. Projects with enabled GitLab CI go first",
                        "order_by" => "Return requests ordered by `id`, `name`, `path`, `created_at`, `updated_at` or `last_activity_at` fields. Default is `created_at`",
                        "search" => "Return list of authorized projects according to a search criteria",
                        "sort" => "Return requests sorted in `asc` or `desc` order. Default is `desc`",
                    }
                },
                "title" => "List owned projects",
            }
        },
        "/projects/search/:query" => {
            "GET" => {
                "params" => {
                    "optional" => {
                        "order_by" => "Return requests ordered by `id`, `name`, `created_at` or `last_activity_at` fields",
                        "page" => "the page to retrieve",
                        "per_page" => "number of projects to return per page",
                        "sort" => "Return requests sorted in `asc` or `desc` order",
                    },
                    "required" => {
                        "query" => "A string contained in the project name",
                    }
                },
                "title" => "Search for projects by name",
            }
        },
        "/projects/user/:user_id" => {
            "POST" => {
                "params" => {
                    "optional" => {
                        "default_branch" => "'master' by default",
                        "description" => "short project description",
                        "issues_enabled" => "`merge_requests_enabled` (optional)",
                        "public" => "if `true` same as setting visibility_level = 20",
                        "visibility_level" => "`import_url` (optional)",
                        "wiki_enabled" => "`snippets_enabled` (optional)",
                    },
                    "required" => {
                        "name" => "new project name",
                        "user_id" => "user_id of owner",
                    }
                },
                "title" => "Create project for user",
            }
        },
        "/user" => {
            "GET" => {
                "title" => "Current user",
            }
        },
        "/user/emails" => {
            "GET" => {
                "title" => "List emails",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "email" => "email address",
                    }
                },
                "title" => "Add email",
            }
        },
        "/user/emails/:id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "email ID",
                    }
                },
                "title" => "Delete email for current user",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "email ID",
                    }
                },
                "title" => "Single email",
            }
        },
        "/user/keys" => {
            "GET" => {
                "title" => "List SSH keys",
            },
            "POST" => {
                "params" => {
                    "required" => {
                        "key" => "new SSH key",
                        "title" => "new SSH Key's title",
                    }
                },
                "title" => "Add SSH key",
            }
        },
        "/user/keys/:id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "SSH key ID",
                    }
                },
                "title" => "Delete SSH key for current user",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of an SSH key",
                    }
                },
                "title" => "Single SSH key",
            }
        },
        "/users" => {
            "GET" => {
                "title" => "For admins",
                "params" => {
                    "optional" => {
                        "search" => "Search for users by name or email",
                    },
                },
            },
            "POST" => {
                "params" => {
                    "optional" => {
                        "admin" => "User is admin - true or false (default)",
                        "bio" => "User's biography",
                        "can_create_group" => "User can create groups - true or false",
                        "confirm" => "Require confirmation - true (default) or false",
                        "extern_uid" => "External UID",
                        "linkedin" => "LinkedIn",
                        "projects_limit" => "Number of projects user can create",
                        "provider" => "External provider name",
                        "skype" => "Skype ID",
                        "twitter" => "Twitter account",
                        "website_url" => "Website URL",
                    },
                    "required" => {
                        "email" => "Email",
                        "name" => "Name",
                        "password" => "Password",
                        "username" => "Username",
                    }
                },
                "title" => "User creation",
            }
        },
        "/users/:id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of the user",
                    }
                },
                "title" => "User deletion",
            },
            "GET" => {
                "params" => {
                    "required" => {
                        "id" => "The ID of a user",
                    }
                },
                "title" => "For admin",
            },
            "PUT" => {
                "params" => {
                    "optional" => {
                        "admin" => "User is admin - true or false (default)",
                        "bio" => "User's biography",
                        "can_create_group" => "User can create groups - true or false",
                        "email" => "Email",
                        "extern_uid" => "External UID",
                        "linkedin" => "LinkedIn",
                        "name" => "Name",
                        "password" => "Password",
                        "projects_limit" => "Limit projects each user can create",
                        "provider" => "External provider name",
                        "skype" => "Skype ID",
                        "twitter" => "Twitter account",
                        "username" => "Username",
                        "website_url" => "Website URL",
                    },
                    "required" => {
                        "id" => "The ID of a user",
                    }
                },
                "title" => "User modification",
            }
        },
        "/users/:id/emails" => {
            "POST" => {
                "params" => {
                    "required" => {
                        "email" => "email address",
                        "id" => "id of specified user",
                    }
                },
                "title" => "Add email for user",
            }
        },
        "/users/:id/keys" => {
            "POST" => {
                "params" => {
                    "required" => {
                        "id" => "id of specified user",
                        "key" => "new SSH key",
                        "title" => "new SSH Key's title",
                    }
                },
                "title" => "Add SSH key for user",
            }
        },
        "/users/:uid/block" => {
            "PUT" => {
                "params" => {
                    "required" => {
                        "uid" => "id of specified user",
                    }
                },
                "title" => "Block user",
            }
        },
        "/users/:uid/emails" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "uid" => "id of specified user",
                    }
                },
                "title" => "List emails for user",
            }
        },
        "/users/:uid/emails/:id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "email ID",
                        "uid" => "id of specified user",
                    }
                },
                "title" => "Delete email for given user",
            }
        },
        "/users/:uid/keys" => {
            "GET" => {
                "params" => {
                    "required" => {
                        "uid" => "id of specified user",
                    }
                },
                "title" => "List SSH keys for user",
            }
        },
        "/users/:uid/keys/:id" => {
            "DELETE" => {
                "params" => {
                    "required" => {
                        "id" => "SSH key ID",
                        "uid" => "id of specified user",
                    }
                },
                "title" => "Delete SSH key for given user",
            }
        },
        "/users/:uid/unblock" => {
            "PUT" => {
                "params" => {
                    "required" => {
                        "uid" => "id of specified user",
                    }
                },
                "title" => "Unblock user",
            }
        },
    };
}

1;
