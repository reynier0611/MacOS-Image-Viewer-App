import Testing

/// The app has a single shared `BrowserModel`, so every test that drives it lives inside this
/// suite: `.serialized` applies to nested suites too, keeping them from running in parallel
/// and navigating the model out from under each other.
@Suite("App model", .serialized)
enum AppModelSuite {}
