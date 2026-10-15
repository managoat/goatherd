# Credo's defaults, run with `mix credo --strict` — except in the code vendored
# from the archived managoat_* libraries (see NOTICE), which was written against
# a config that disabled the checks below as pre-existing tech debt. Exempting
# those paths, rather than rewriting them, keeps the vendored files diffable
# against their source. goatherd's own code gets every check.
vendored = %{excluded: ["lib/managoat/", "test/managoat/", "test/support/", "test/live/"]}

exempt = [
  Credo.Check.Design.AliasUsage,
  Credo.Check.Readability.AliasOrder,
  Credo.Check.Readability.MaxLineLength,
  Credo.Check.Readability.ParenthesesOnZeroArityDefs,
  Credo.Check.Readability.PreferImplicitTry,
  Credo.Check.Readability.WithSingleClause,
  Credo.Check.Refactor.Apply,
  Credo.Check.Refactor.CondStatements,
  Credo.Check.Refactor.CyclomaticComplexity,
  Credo.Check.Refactor.Nesting
]

%{
  configs: [
    %{
      name: "default",
      checks: %{extra: Enum.map(exempt, &{&1, [files: vendored]})}
    }
  ]
}
