# GitLab::API::Basic

A simple API client for the GitLab API.

## Important Note

The GitLab API documentation states in various places that projects may be
accessed either via "project ID or NAMESPACE/PROJECT_NAME", for example, see
the /projects/:id docs at

https://gitlab.com/help/api/projects.md#get-single-project

While theoretically the API may support the use of NAMESPACE/PROJECT_NAME,
in pratice it appears to be so **horribly unreliable** and should be
considered unusable, and avoided at all costs. Using project IDs appears
to be reliable, and if all else fails fetching all the projects for a user
and searching for the required project in the result will yield the
project ID.