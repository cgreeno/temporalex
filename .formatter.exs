# Used by "mix format"
# Used by "mix format"
# Proto files are auto-generated and excluded from formatting.
[
  inputs:
    ["{mix,.formatter}.exs", "{config,test}/**/*.{ex,exs}"] ++
      (Path.wildcard("lib/**/*.{ex,exs}") -- Path.wildcard("lib/temporalex/proto/**/*.ex"))
]
