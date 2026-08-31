# Stub for `require "spaceship"`.
#
# version_resolver.rb requires spaceship at load time for the ASC query half of
# next_build_number. The arithmetic half — next_build_after — never touches it,
# and the sibling tests (parser_test, sh_stream_test) are deliberately
# stdlib-only so their CI job needs no bundle install.
#
# Loading this stub first satisfies the require without pulling in fastlane.
# It defines nothing: any test that actually reaches Spaceship will fail loudly
# with NameError rather than silently exercising a mock that agrees with itself.
