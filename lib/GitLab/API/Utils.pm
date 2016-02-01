package GitLab::API::Utils;

use GitLab::API::Basic;
use REST::Client 0.273.1;
use Carp qw(croak carp);
use JSON;
use strict;
use Data::Dumper;
our $VERSION = '0.1.0';

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new GitLab::API::Utils object to perform GitLab API operations through.
# All arguments are passed through to an internally-created GitLab::API::Basic
# object, unless an api argument is provided.
#
# @return A new GitLab::API::Utils object
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        api   => undef,
        url   => undef,
        token => undef,
        sudo  => undef,
        @_,
    };

    # Build an API object if needed.
    $self -> {"api"} = GitLab::API::Basic -> new(url   => $self -> {"url"},
                                                 token => $self -> {"token"},
                                                 sudo  => $self -> {"sudo"})
        unless($self -> {"api"} && ref($self -> {"api"}) eq "GitLab::API::Basic");

    return bless $self, $class;
}


# ============================================================================
#  Deep forking facilities

## @method private $ _clone_labels($sourceid, $destid)
# Copy the labels defined in the source project into the destination project.
#
# @note The project IDs specified must be GitLab internal numeric IDs, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param sourceid The ID of the project to copy the labels from.
# @param destid   The ID of the project to copy the labels into.
# @return true on success, undef on error.
sub _clone_labels {
    my $self     = shift;
    my $sourceid = shift;
    my $destid   = shift;

    $self -> clear_error();

    my $labels = $self -> {"api"} -> call("/projects/:id/labels", "GET", { id => $sourceid });
    return $self -> self_error("Label lookup failed: ".$self -> {"api"} -> errstr())
        unless($labels);

    foreach my $label (@{$labels}) {
        my $res = $self -> {"api"} -> call("/projects/:id/labels", "POST", { id    => $destid,
                                                                             name  => $label -> {"name"},
                                                                             color => $label -> {"color"}
                                           });
        return $self -> self_error("Label creation failed: ".$self -> {"api"} -> errstr())
            unless($res);
    }

    return 1;
}


## @method private $ _clone_notes($sourceid, $fromissue, $destid, $toissue)
# Copy the notes on the given issue in the source project into an issue in
# the destination project.
#
# @note The project IDs specified must be GitLab internal numeric IDs, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param sourceid  The ID of the project to copy the issue notes from.
# @param fromissue The ID of the issue to copy the notes from.
# @param destid    The ID of the project to copy the notes to.
# @param toissue   The ID of the issue to copy the notes into.
# @return true on success, undef on error.
sub _clone_notes {
    my $self      = shift;
    my $sourceid  = shift;
    my $fromissue = shift;
    my $destid    = shift;
    my $toissue   = shift;

    my $notes = $self -> {"api"} -> call("/projects/:id/issues/:issue_id/notes", "GET", { id       => $sourceid,
                                                                                          issue_id => $fromissue});
    foreach my $note (@{$notes}) {
        my $res = $self -> {"api"} -> call("/projects/:id/issues/:issue_id/notes", "POST", { id       => $destid,
                                                                                             issue_id => $toissue,
                                                                                             body     => $note -> {"body"} });
        return $self -> self_error("Note creation failed: ".$self -> {"api"} -> errstr())
            unless($res);
    }

    return 1;
}


## @method private $ _clone_milestones($sourceid, $destid)
# Copy the milestones defined in the source project into the destination project.
#
# @note The project IDs specified must be GitLab internal numeric IDs, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param sourceid The ID of the project to copy the milestones from.
# @param destid   The ID of the project to copy the milestones into.
# @return A reference to a hash that maps IDs of milestones in the source
#         project to the IDs of milestones in the destination, undef on error.
sub _clone_milestones {
    my $self     = shift;
    my $sourceid = shift;
    my $destid   = shift;

    my $milestones = $self -> {"api"} -> call("/projects/:id/milestones", "GET", { id => $sourceid });
    return $self -> self_error("Label lookup failed: ".$self -> {"api"} -> errstr())
        unless($milestones);

    my $mapping = {};
    foreach my $milestone (@{$milestones}) {
        my $res = $self -> {"api"} -> call("/projects/:id/milestones", "POST", { id          => $destid,
                                                                                 title       => $milestone -> {"title"},
                                                                                 description => $milestone -> {"description"},
                                                                                 due_date    => $milestone -> {"due_date"}
                               });
        return $self -> self_error("Milestone creation failed: ".$self -> {"api"} -> errstr())
            unless($res);

        $mapping -> {$milestone -> {"id"}} = $res -> {"id"};
    }

    return $mapping;
}


## @method private $ _clone_issues($sourceid, $destid, $milestones)
# Copy the issues defined in the source project into the destination project.
#
# @note The project IDs specified must be GitLab internal numeric IDs, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param sourceid   The ID of the project to copy the issues from.
# @param destid     The ID of the project to copy the issues into.
# @param milestones A reference to a hash that maps IDs of milestones in the source
#                   project to the IDs of milestones in the destination. If not
#                   specified, milestones are note set on the destination issues.
# @return true on success, undef on error.
sub _clone_issues {
    my $self       = shift;
    my $sourceid   = shift;
    my $destid     = shift;
    my $milestones = shift;

    # Pull the list of issues on the source
    my $issues = $self -> {"api"} -> call("/projects/:id/issues", "GET" , { id    => $sourceid,
                                                                            state => "opened" });
    return $self -> self_error("Issue lookup failed: ".$self -> {"api"} -> errstr())
        unless($issues);

    # And set the issues in the destination
    foreach my $issue (@{$issues}) {
        my $newdata = { id          => $destid,
                        title       => $issue -> {"title"},
                        description => $issue -> {"description"} };

        $newdata -> {"labels"} = join(",", @{$issue -> {"labels"}})
            if($issue -> {"labels"} && scalar(@{$issue -> {"labels"}}));

        # If there's a milestone, set it on the new issue with a remapped ID
        $newdata -> {"milestone_id"} = $milestones -> {$issue -> {"milestone"} -> {"id"}}
            if($issue -> {"milestone"} && $issue -> {"milestone"} -> {"id"} && $milestones -> {$issue -> {"milestone"} -> {"id"}});

        my $res = $self -> {"api"} -> call("/projects/:id/issues", "POST", $newdata);
        return $self -> self_error("Issue creation failed: ".$self -> {"api"} -> errstr())
            unless($res);

        $self -> _clone_notes($sourceid, $issue -> {"id"}, $destid, $res -> {"id"})
            or return undef;
    }

    return 1;
}


## @method $ deep_fork($sourceid, $set_milestones)
# Perform a deep fork of a project. This creates a fork of a project, duplicating the
# issues, labels, comments, and milestones to the new fork. The project will be forked
# into the namespace of the current user (or sudo-ed user).
#
# @note The project ID specified must be a GitLab internal numeric ID, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param sourceid       The ID of the project to fork.
# @param set_milestones If true, and issues in the source project have milestones set,
#                       set those milestones in the issues in the fork. If not set,
#                       this defaults to true.
# @return The ID of the new project on success, undef on error.
sub deep_fork {
    my $self           = shift;
    my $sourceid       = shift;
    my $set_milestones = shift // 1;

    my $res = $self -> {"api"} -> call("/projects/:id", "GET", { id => $sourceid });
    return $self -> self_error("Project lookup failed: ".$self -> {"api"} -> errstr())
        if(!$res);

    my $fork = $self -> {"api"} -> call("/projects/fork/:id", "POST", { id => $sourceid });
    return $self -> self_error("Project fork failed: ".$self -> {"api"} -> errstr())
        if(!$fork);

    $self -> _clone_labels($sourceid, $fork -> {"id"})
        or return undef;

    my $milestones = $self -> _clone_milestones($sourceid, $fork -> {"id"})
        or return undef;

    $self -> _clone_issues($sourceid, $fork -> {"id"}, $set_milestones ? $milestones : {} )
        or return undef;

    return $fork -> {"id"};
}


# ============================================================================
#  Convenience features

## @method $ move_project($projid, $groupname)
# Move the specified project into the group with the specified name.
#
# @note The project ID specified must be a GitLab internal numeric ID, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param projid    The ID of the project to move.
# @param groupname The name of the group to move the project to.
# @return true on success, undef on error.
sub move_project {
    my $self      = shift;
    my $projid    = shift;
    my $groupname = shift;

    $self -> clear_error();

    my $res = $self -> {"api"} -> call("/groups", "GET", { search => $groupname });
    return $self -> self_error("Group lookup failed: ".$self -> {"api"} -> errstr())
        if(!$res || !scalar(@{$res}));

    $res = $self -> {"api"} -> call("/groups/:id/projects/:project_id", "POST", { project_id => $projid,
                                                                                  id         => $res -> [ 0 ] -> {"id"} });
    return $self -> self_error("Project transfer failed: ".$self -> {"api"} -> errstr())
        if(!$res);

    return 1;
}


## @method $ rename_project($projid, $name)
# Rename the specified project, changing its name and path.
#
# @note The project ID specified must be a GitLab internal numeric ID, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param projid    The ID of the project to move.
# @param name      The new name to set for the project.
# @return true on success, undef on error.
sub rename_project {
    my $self   = shift;
    my $projid = shift;
    my $name   = shift;

    $self -> clear_error();

    my $res = $self -> {"api"} -> call("/projects/:id", "PUT", { id => $projid,
                                                                 name => $name,
                                                                 path => $name
                                       });
    return $self -> self_error("Project rename failed: ".$self -> {"api"} -> errstr())
        unless($res);

    return 1;
}


# ============================================================================
#  User control

## @method $ lookup_users($emails)
# Convert the specified list of user emails to GitLab internal user IDs.
# If an email address can not be converted to an ID, the corresponding entry
# in the returned array will be set to undef.
#
# @param emails A reference to an array of email addresses to resolve.
# @return A reference to an array of converted user IDs.
sub lookup_users {
    my $self   = shift;
    my $emails = shift;

    my $userids;
    foreach my $email (@{$emails}) {
        my $res = $self -> {"api"} -> call("/users", "GET", { search => $email });

        push(@{$userids}, $res -> [0] -> {"id"})
            if($res && scalar(@{$res}));
    }

    return $userids;
}


## @method $ add_users($projectid, $userids, $level)
# Add users to the specified project at the given level. Add one or more users to
# the project at the specifed level, where all the users are added at the same
# level.
#
# @note The project ID specified must be a GitLab internal numeric ID, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param projectid  The ID of the project to add users to.
# @param userids    A user ID or a reference to an array of user IDs of users to
#                   add to the project.
# @param level      The level to add users at, see the access_levels hash in the
#                   GitLab::API::Basic for supported levels. If not specified,
#                   users are added at level 30 ('developer').
# @return true on success, undef on error.
sub add_users {
    my $self      = shift;
    my $projectid = shift;
    my $userids   = shift;
    my $level     = shift // $self -> {"api"} -> {"access_levels"} -> {"developer"};

    # Ensure the userids are in an arrayref.
    $userids = [ $userids ]
        if(!ref($userids));

    $self -> clear_error();

    # Add each user to the project, hopefully they aren't there already!
    foreach my $userid (@{$userids}) {
        my $res = $self -> {"api"} -> call("/projects/:id/members", "POST", { 'id'           => $projectid,
                                                                              'user_id'      => $userid,
                                                                              'access_level' => $level
                                           });

        return $self -> self_error("Unable to add user $userid to project $projectid: ".$self -> {"api"} -> errstr())
            unless($res);
    }

    return 1;
}


## @method $ set_user_access($projectid, $userids, $level)
# Update the access level for the specified user(s) in the given project.
#
# @note The project ID specified must be a GitLab internal numeric ID, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param projectid  The ID of the project to set the access level of the users in.
# @param userids    A user ID or a reference to an array of user IDs of users to
#                   set the access level for.
# @param level      The level to set for the users, see the access_levels hash in the
#                   GitLab::API::Basic for supported levels. If not specified,
#                   users set to level 30 ('developer').
# @return true on success, undef on error.
sub set_user_access {
    my $self      = shift;
    my $projectid = shift;
    my $userids   = shift;
    my $level     = shift // $self -> {"api"} -> {"access_levels"} -> {"developer"};

    # Ensure the userids are in an arrayref.
    $userids = [ $userids ]
        if(!ref($userids));

    $self -> clear_error();

    # Update the user's access level
    foreach my $userid (@{$userids}) {
        my $res = $self -> {"api"} -> call("/projects/:id/members/:user_id", "PUT", { 'id'           => $projectid,
                                                                                      'user_id'      => $userid,
                                                                                      'access_level' => $level
                                           });

        return $self -> self_error("Unable to set user $userid access on project $projectid: ".$self -> {"api"} -> errstr())
            unless($res);
    }

    return 1;
}


## @method $ remove_users($projectid, $userids)
# Remove the specified users from the project.
#
# @note The project ID specified must be a GitLab internal numeric ID, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param projectid The ID of the project to remove the users from.
# @param userids   A user ID or reference to an array of user IDs of users to
#                  remove from the project.
# @return true on success, undef on error.
sub remove_users {
    my $self      = shift;
    my $projectid = shift;
    my $userids   = shift;

    # Ensure the userids are in an arrayref.
    $userids = [ $userids ]
        if(!ref($userids));

    $self -> clear_error();

    # Remove the users from the project.
    foreach my $userid (@{$userids}) {
        my $res = $self -> {"api"} -> call("/projects/:id/members/:user_id", "DELETE", { 'id'           => $projectid,
                                                                                         'user_id'      => $userid
                                           });

        return $self -> self_error("Unable to remove user $userid from project $projectid: ".$self -> {"api"} -> errstr())
            unless($res);
    }

    return 1;
}


## @method $ set_users($projectid, $users)
# Modify the users set on the specified project to match the specified users.
# This will remove any users not present in the specified hashref, and add
# users who are in the user hashref but not set on the project.
#
# @note The project ID specified must be a GitLab internal numeric ID, *not* the
#       NAMESPACE/PROJECT_NAME format GitLab claims to support but doesn't really.
# @param projectid The ID of the project to remove the users from.
# @param users     A reference to a hash of users to set on the project. The
#                  keys should be the user IDs and the value should be the
#                  access level to add the user at.
# @return true on success, undef on error.
sub set_users {
    my $self      = shift;
    my $projectid = shift;
    my $users     = shift;

    $self -> clear_error();

    # Fetch the list of currently set users
    my $curlist = $self -> {"api"} -> call("/projects/:id/members", "GET", { id => $projectid });
    return $self -> self_error("Unable to fetch list of user for project $projectid: ".$self -> {"api"} -> errstr())
        unless($curlist);

    # convert to a hash to make lookup faster.
    my $curhash = {};
    foreach my $user (@{$curlist}) {
        $curhash -> {$user -> {"id"}} = $user;
    }

    # Go through the list of userids specified, working out which need to be added
    # or have their access levels fixed
    foreach my $userid (keys(%{$users})) {
        if($curhash -> {$userid}) {
            $self -> set_user_access($projectid, $userid, $users -> {$userid})
                or return undef;
        } else {
            $self -> add_users($projectid, $userid, $users -> {$userid})
                or return undef;
        }
    }

    # Now work out which users need to be removed - are they in the current list
    # but not in the set hash?
    foreach my $user (@{$curlist}) {
        $self -> remove_users($projectid, $user -> {"id"}) or return undef
            unless($users -> {$user -> {"id"}});
    }

    return 1;
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


1;