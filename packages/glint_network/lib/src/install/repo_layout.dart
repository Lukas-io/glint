/// Where glint_network lives inside the glint repository; `dart pub global activate -s git` takes it as `--git-path`.
const String packageGitPath = 'packages/glint_network';

/// Pub names its git checkouts `<repo>-<commit>`, so the glint repository lands in `<pub_cache>/git/glint-<commit>`.
const String repoCheckoutPrefix = 'glint-';
