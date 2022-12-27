import Lean
import Mathlib.Control.Writer
import PremiseSelection.StatementFeatures 
import PremiseSelection.ProofSource 

namespace PremiseSelection

open Lean Lean.Elab Lean.Elab.Term Lean.Elab.Command Lean.Meta System

/-- Holds the name, features and premises of a single theorem. -/
structure TheoremPremises where 
  name              : Name 
  features          : StatementFeatures
  argumentsFeatures : List StatementFeatures
  premises          : Multiset Name 

instance : ToJson TheoremPremises where 
  toJson data := 
    Json.mkObj [
      ("name",              toJson data.name),
      ("features",          toJson data.features),
      ("argumentsFeatures", toJson data.argumentsFeatures),
      ("premises",          toJson data.premises)
    ]

instance : ToString TheoremPremises where 
  toString := Json.pretty ∘ toJson

/-- Used to choose the feature format: nameCounts and/or bigramCounts and/or 
subexpressions -/
structure FeatureFormat where 
  n : Bool := true 
  b : Bool := false 
  s : Bool := true 
deriving Inhabited

/-- Structure to put together all the user options: max expression depth, filter
user premises and feature format. -/
structure UserOptions where 
  minDepth : UInt32        := 0
  maxDepth : UInt32        := 255  
  user     : Bool          := false 
  format   : FeatureFormat := default
deriving Inhabited

/-- Features used for training. All the features (arguments and theorem) should 
be put together in a sequence tageged with `T` for theorem or `H` for 
hypotheses.  -/
def getFeatures (tp : TheoremPremises) (format : FeatureFormat) : String := 
  Id.run <| do
    let mut result : Array String := #[]
    if format.n then
      for (n, _) in tp.features.nameCounts do
        result := result.push s!"T:{n}"
      for arg in tp.argumentsFeatures do 
        for (n, _) in arg.nameCounts do
          result := result.push s!"H:{n}"
    if format.b then 
      for (b, _) in tp.features.bigramCounts do
        result := result.push s!"T:{b}"
      for arg in tp.argumentsFeatures do 
        for (b, _) in arg.bigramCounts do
          result := result.push s!"H:{b}"
    if format.s then 
      for (s, _) in tp.features.subexpressions do
        result := result.push <| (s!"T:{s}").trim
      for arg in tp.argumentsFeatures do 
        for (s, _) in arg.subexpressions do
          result := result.push <| (s!"H:{s}").trim
    return " ".intercalate result.data

/-- Premises are simply concatenated. -/
def getLabels (tp : TheoremPremises) : String :=
  " ".intercalate (tp.premises.toList.map toString)

section CoreExtractor

/-- Given a name `n`, if it qualifies as a premise, it returns `[n]`, otherwise 
it returns the empty list. -/
private def getTheoremFromName (n : Name) : MetaM (Multiset Name) := do 
  -- NOTE: Get all consts whose type is of type Prop.
  if let some cinfo := (← getEnv).find? n then
    if (← inferType cinfo.type).isProp then 
      pure (Multiset.singleton n) 
    else 
      pure Multiset.empty
  else pure Multiset.empty

private def getTheoremFromExpr (e : Expr) : MetaM (Multiset Name) := do
  if let .const n _ := e then getTheoremFromName n else pure Multiset.empty

private def visitPremise (e : Expr) : WriterT (Multiset Name) MetaM Unit := do
  getTheoremFromExpr e >>= tell

private def extractPremises (e : Expr) : MetaM (Multiset Name) := do 
  let ((), premises) ← WriterT.run <| forEachExpr visitPremise e
  pure premises

/-- Given a `ConstantInfo` that holds theorem data, it finds the premises used 
in the proof and constructs an object of type `PremisesData` with all. -/
private def extractPremisesFromConstantInfo 
  (minDepth : UInt32 := 0) (maxDepth : UInt32 := 255)
  : ConstantInfo → MetaM (Option TheoremPremises)
  | ConstantInfo.thmInfo { name := n, type := ty, value := v, .. } => do
    forallTelescope ty <| fun args thm => do
      let thmFeats ← getStatementFeatures thm
      let mut argsFeats := []
      for arg in args do
        let argType ← inferType arg
        if (← inferType argType).isProp then
          let argFeats ← getStatementFeatures argType 
          if ! argFeats.bigramCounts.isEmpty then 
            argsFeats := argsFeats ++ [argFeats]
      -- Heuristic that can be used to ignore simple theorems and to avoid long 
      -- executions for deep theorems.
      if minDepth <= v.approxDepth && v.approxDepth < maxDepth then 
        pure <| TheoremPremises.mk n thmFeats argsFeats (← extractPremises v)
      else 
        pure none
  | _ => pure none

end CoreExtractor 

section Variants

/-- Same as `extractPremisesFromConstantInfo` but take an idenitfier and gets 
its information from the environment. -/
def extractPremisesFromId 
  (minDepth : UInt32 := 0) (maxDepth : UInt32 := 255) (id : Name) 
  : MetaM (Option TheoremPremises) := do
  if let some cinfo := (← getEnv).find? id then 
    extractPremisesFromConstantInfo minDepth maxDepth cinfo
  else pure none

/-- Extract and print premises from a single theorem. -/
def extractPremisesFromThm  
  (minDepth : UInt32 := 0) (maxDepth : UInt32 := 255) (stx : Syntax)
  : MetaM (Array TheoremPremises) := do
  let mut thmData : Array TheoremPremises := #[]
  for name in ← resolveGlobalConst stx do 
    if let some data ← extractPremisesFromId minDepth maxDepth name then
      thmData := thmData.push data
  return thmData 

/-- Extract and print premises from all the theorems in the context. -/
def extractPremisesFromCtx (minDepth : UInt32 := 0) (maxDepth : UInt32 := 255)
  : MetaM (Array TheoremPremises) := do 
  let mut ctxData : Array TheoremPremises := #[]
  for (_, cinfo) in (← getEnv).constants.toList do 
    let data? ← extractPremisesFromConstantInfo minDepth maxDepth cinfo
    if let some data := data? then
      ctxData := ctxData.push data
  return ctxData

end Variants 

section FromImports

open IO IO.FS

/-- Given a way to insert `TheoremPremises`, this function goes through all
the theorems in a module, extracts the premises filtering them appropriately 
and inserts the resulting data. -/
private def extractPremisesFromModule
  (insert : TheoremPremises → IO Unit)
  (moduleName : Name) (moduleData : ModuleData) 
  (minDepth maxDepth : UInt32) (user : Bool := false)
  : MetaM Unit := do
  dbg_trace s!"Extracting premises from {moduleName}."
  let mut filter : Name → Multiset Name → MetaM (Multiset Name × Bool) := 
    fun _ ns => pure (ns, true)
  if user then 
    if let some modulePath ← pathFromMathbinImport moduleName then 
      -- If user premises and path found, then create a filter looking at proof 
      -- source. If no proof source is found, no filter is applied.
      filter := fun thmName premises => do
        let premises ← filterUserPremisesFromFile premises modulePath
        if let some source ← proofSource thmName modulePath then
          return (filterUserPremises premises source, true)
        else return (premises, false)
  -- Go through all theorems in the module, filter premises and write.
  let mut countFound := 0
  let mut countTotal := 0
  for cinfo in moduleData.constants do 
    -- Ignore non-user definitions.
    if badTheoremName cinfo.name then 
      continue
    let data? ← extractPremisesFromConstantInfo minDepth maxDepth cinfo
    if let some data := data? then 
      let (filteredPremises, found) ← filter data.name data.premises
      if found then 
        countFound := countFound + 1
      countTotal := countTotal + 1
      if !filteredPremises.isEmpty then 
        let filteredData := { data with premises := filteredPremises }
        insert filteredData
  if user then
    dbg_trace s!"Successfully filtered {countFound}/{countTotal}."
  pure ()
where 
  badTheoremName (n : Name) : Bool := 
  let s := toString n
  s.contains '!' || s.contains '«' || 
  "_eqn_".isSubstrOf s || "_proof_".isSubstrOf s || "_match_".isSubstrOf s

/-- Call `extractPremisesFromModule` with an insertion mechanism that writes
to the specified files for labels and features. -/
def extractPremisesFromModuleToFiles 
  (moduleName : Name) (moduleData : ModuleData) 
  (labelsPath featuresPath : FilePath) (userOptions : UserOptions := default)
  : MetaM Unit := do 
  let labelsHandle ← Handle.mk labelsPath Mode.append false
  let featuresHandle ← Handle.mk featuresPath Mode.append false

  let insert : TheoremPremises → IO Unit := fun data => do
    labelsHandle.putStrLn (getLabels data)
    featuresHandle.putStrLn (getFeatures data userOptions.format)
  
  let minDepth := userOptions.minDepth
  let maxDepth := userOptions.maxDepth
  let user := userOptions.user
  extractPremisesFromModule insert moduleName moduleData minDepth maxDepth user

/-- Looks through all the meaningful imports and applies 
`extractPremisesFromModuleToFiles` to each of them. -/
def extractPremisesFromImportsToFiles 
  (labelsPath featuresPath : FilePath) (userOptions : UserOptions := default) 
  : MetaM Unit := do 
  dbg_trace s!"Clearing {labelsPath} and {featuresPath}."

  IO.FS.writeFile labelsPath ""
  IO.FS.writeFile featuresPath ""

  dbg_trace s!"Extracting premises from imports to {labelsPath}, {featuresPath}."

  let env ← getEnv
  let imports := env.imports.map (·.module)
  let moduleNamesArray := env.header.moduleNames
  let moduleDataArray := env.header.moduleData

  let mut count := 0
  for (moduleName, moduleData) in Array.zip moduleNamesArray moduleDataArray do
    let isMathbinImport := 
      moduleName.getRoot == `Mathbin || moduleName == `Mathbin
    if imports.contains moduleName && isMathbinImport then 
      count := count + 1
      extractPremisesFromModuleToFiles 
        moduleName moduleData labelsPath featuresPath userOptions
      dbg_trace s!"count = {count}."
          
  pure ()

end FromImports

section Json

def extractPremisesFromCtxJson : MetaM Json := 
  toJson <$> extractPremisesFromCtx

def extractPremisesFromThmJson (stx : Syntax) : MetaM Json := 
  toJson <$> extractPremisesFromThm (stx := stx)

end Json

section Commands 

private def runAndPrint [ToJson α] (f : MetaM α) : CommandElabM Unit :=
  liftTermElabM <| do dbg_trace s!"{Json.pretty <| toJson <| ← f}"

elab "extract_premises_from_thm " id:term : command =>
  runAndPrint <| extractPremisesFromThm (stx := id)

elab "extract_premises_from_ctx" : command =>
  runAndPrint <| extractPremisesFromCtx

syntax (name := extract_premises_to_files) 
  "extract_premises_to_files l:" str " f:" str : command

@[commandElab «extract_premises_to_files»]
unsafe def elabExtractPremisesToFiles : CommandElab
| `(extract_premises_to_files l:$lp f:$fp) => liftTermElabM <| do
  let labelsPath ← evalTerm String (mkConst `String) lp.raw
  let featuresPath ← evalTerm String (mkConst `String) fp.raw
  extractPremisesFromImportsToFiles labelsPath featuresPath
| _ => throwUnsupportedSyntax

end Commands 

end PremiseSelection
