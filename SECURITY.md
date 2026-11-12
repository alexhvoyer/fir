# Security

## Reporting a vulnerability

Please report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**.
Don't open a public issue for anything that could be exploited before it is fixed.

Include what you found, how to reproduce it, and which build you used (the TestFlight app shows its number).
Expect a first reply within a week.

## Supported versions

Only the latest TestFlight build and the `main` branch get fixes.

## What matters most

Fir is a browser, so its own code decides what a page can reach. Reports in these areas are especially welcome:

- Address bar spoofing: the bar or the connection details showing an address the page doesn't come from.
- Password autofill filling a login into a page of another origin, or into a frame the user didn't pick.
- Private tabs leaving anything on disk or outside the app.
- Getting past the app lock.
- Opening another app or a URL scheme without the user agreeing.
- Add-on installation: packages from anywhere but addons.mozilla.org, or extracted files landing outside their folder.

Bugs in WebKit itself belong with Apple at https://security.apple.com.
