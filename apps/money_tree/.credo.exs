%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "config/", "test/"],
        excluded: ["_build/", "deps/", "priv/"]
      },
      checks: [
        {Credo.Check.Consistency.LineEndings, []},
        {Credo.Check.Consistency.SpaceAroundOperators, []},
        {Credo.Check.Design.TagTODO, [exit_status: 0]},
        {Credo.Check.Design.TagFIXME, [exit_status: 0]},
        {Credo.Check.Readability.MaxLineLength, [max_length: 120]},
        {Credo.Check.Readability.ModuleDoc, []},
        {Credo.Check.Readability.StrictModuleLayout, []},
        {Credo.Check.Refactor.Apply, []},
        {Credo.Check.Refactor.CondStatements, []},
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15]},
        {Credo.Check.Refactor.FunctionArity, [max_arity: 8]},
        {Credo.Check.Refactor.MapInto, []},
        {Credo.Check.Warning.IExPry, []},
        {Credo.Check.Warning.IoInspect, []},
        {Credo.Check.Warning.UnusedEnumOperation, []},
        {Credo.Check.Warning.UnusedKeywordOperation, []},
        {Credo.Check.Warning.UnusedListOperation, []},
        {Credo.Check.Warning.UnusedStringOperation, []},
        {Credo.Check.Warning.UnusedTupleOperation, []}
      ]
    }
  ]
}
