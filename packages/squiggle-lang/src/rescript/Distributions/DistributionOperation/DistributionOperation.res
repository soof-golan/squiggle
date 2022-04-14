type functionCallInfo = GenericDist_Types.Operation.genericFunctionCallInfo
type genericDist = DistributionTypes.genericDist
type error = DistributionTypes.error

// TODO: It could be great to use a cache for some calculations (basically, do memoization). Also, better analytics/tracking could go a long way.

type env = {
  sampleCount: int,
  xyPointLength: int,
}

type outputType =
  | Dist(genericDist)
  | Float(float)
  | String(string)
  | GenDistError(error)

/*
We're going to add another function to this module later, so first define a
local version, which is not exported.
*/
module OutputLocal = {
  type t = outputType

  let toError = (t: outputType) =>
    switch t {
    | GenDistError(d) => Some(d)
    | _ => None
    }

  let toErrorOrUnreachable = (t: t): error => t->toError->E.O2.default((Unreachable: error))

  let toDistR = (t: t): result<genericDist, error> =>
    switch t {
    | Dist(r) => Ok(r)
    | e => Error(toErrorOrUnreachable(e))
    }

  let toDist = (t: t) =>
    switch t {
    | Dist(d) => Some(d)
    | _ => None
    }

  let toFloat = (t: t) =>
    switch t {
    | Float(d) => Some(d)
    | _ => None
    }

  let toFloatR = (t: t): result<float, error> =>
    switch t {
    | Float(r) => Ok(r)
    | e => Error(toErrorOrUnreachable(e))
    }

  let toString = (t: t) =>
    switch t {
    | String(d) => Some(d)
    | _ => None
    }

  let toStringR = (t: t): result<string, error> =>
    switch t {
    | String(r) => Ok(r)
    | e => Error(toErrorOrUnreachable(e))
    }

  //This is used to catch errors in other switch statements.
  let fromResult = (r: result<t, error>): outputType =>
    switch r {
    | Ok(t) => t
    | Error(e) => GenDistError(e)
    }
}

let rec run = (~env, functionCallInfo: functionCallInfo): outputType => {
  let {sampleCount, xyPointLength} = env

  let reCall = (~env=env, ~functionCallInfo=functionCallInfo, ()) => {
    run(~env, functionCallInfo)
  }

  let toPointSetFn = r => {
    switch reCall(~functionCallInfo=FromDist(ToDist(ToPointSet), r), ()) {
    | Dist(PointSet(p)) => Ok(p)
    | e => Error(OutputLocal.toErrorOrUnreachable(e))
    }
  }

  let toSampleSetFn = r => {
    switch reCall(~functionCallInfo=FromDist(ToDist(ToSampleSet(sampleCount)), r), ()) {
    | Dist(SampleSet(p)) => Ok(p)
    | e => Error(OutputLocal.toErrorOrUnreachable(e))
    }
  }

  let scaleMultiply = (r, weight) =>
    reCall(
      ~functionCallInfo=FromDist(ToDistCombination(Pointwise, #Multiply, #Float(weight)), r),
      (),
    )->OutputLocal.toDistR

  let pointwiseAdd = (r1, r2) =>
    reCall(
      ~functionCallInfo=FromDist(ToDistCombination(Pointwise, #Add, #Dist(r2)), r1),
      (),
    )->OutputLocal.toDistR

  let fromDistFn = (subFnName: GenericDist_Types.Operation.fromDist, dist: genericDist) =>
    switch subFnName {
    | ToFloat(distToFloatOperation) =>
      GenericDist.toFloatOperation(dist, ~toPointSetFn, ~distToFloatOperation)
      ->E.R2.fmap(r => Float(r))
      ->OutputLocal.fromResult
    | ToString(ToString) => dist->GenericDist.toString->String
    | ToString(ToSparkline(bucketCount)) =>
      GenericDist.toSparkline(dist, ~sampleCount, ~bucketCount, ())
      ->E.R2.fmap(r => String(r))
      ->OutputLocal.fromResult
    | ToDist(Inspect) => {
        Js.log2("Console log requested: ", dist)
        Dist(dist)
      }
    | ToDist(Normalize) => dist->GenericDist.normalize->Dist
    | ToDist(Truncate(leftCutoff, rightCutoff)) =>
      GenericDist.truncate(~toPointSetFn, ~leftCutoff, ~rightCutoff, dist, ())
      ->E.R2.fmap(r => Dist(r))
      ->OutputLocal.fromResult
    | ToDist(ToSampleSet(n)) =>
      dist
      ->GenericDist.toSampleSetDist(n)
      ->E.R2.fmap(r => Dist(SampleSet(r)))
      ->OutputLocal.fromResult
    | ToDist(ToPointSet) =>
      dist
      ->GenericDist.toPointSet(~xyPointLength, ~sampleCount, ())
      ->E.R2.fmap(r => Dist(PointSet(r)))
      ->OutputLocal.fromResult
    | ToDistCombination(Algebraic, _, #Float(_)) => GenDistError(NotYetImplemented)
    | ToDistCombination(Algebraic, arithmeticOperation, #Dist(t2)) =>
      dist
      ->GenericDist.algebraicCombination(~toPointSetFn, ~toSampleSetFn, ~arithmeticOperation, ~t2)
      ->E.R2.fmap(r => Dist(r))
      ->OutputLocal.fromResult
    | ToDistCombination(Pointwise, arithmeticOperation, #Dist(t2)) =>
      dist
      ->GenericDist.pointwiseCombination(~toPointSetFn, ~arithmeticOperation, ~t2)
      ->E.R2.fmap(r => Dist(r))
      ->OutputLocal.fromResult
    | ToDistCombination(Pointwise, arithmeticOperation, #Float(float)) =>
      dist
      ->GenericDist.pointwiseCombinationFloat(~toPointSetFn, ~arithmeticOperation, ~float)
      ->E.R2.fmap(r => Dist(r))
      ->OutputLocal.fromResult
    }

  switch functionCallInfo {
  | FromDist(subFnName, dist) => fromDistFn(subFnName, dist)
  | FromFloat(subFnName, float) =>
    reCall(~functionCallInfo=FromDist(subFnName, GenericDist.fromFloat(float)), ())
  | Mixture(dists) =>
    dists
    ->GenericDist.mixture(~scaleMultiplyFn=scaleMultiply, ~pointwiseAddFn=pointwiseAdd)
    ->E.R2.fmap(r => Dist(r))
    ->OutputLocal.fromResult
  }
}

let runFromDist = (~env, ~functionCallInfo, dist) => run(~env, FromDist(functionCallInfo, dist))
let runFromFloat = (~env, ~functionCallInfo, float) => run(~env, FromFloat(functionCallInfo, float))

module Output = {
  include OutputLocal

  let fmap = (
    ~env,
    input: outputType,
    functionCallInfo: GenericDist_Types.Operation.singleParamaterFunction,
  ): outputType => {
    let newFnCall: result<functionCallInfo, error> = switch (functionCallInfo, input) {
    | (FromDist(fromDist), Dist(o)) => Ok(FromDist(fromDist, o))
    | (FromFloat(fromDist), Float(o)) => Ok(FromFloat(fromDist, o))
    | (_, GenDistError(r)) => Error(r)
    | (FromDist(_), _) => Error(Other("Expected dist, got something else"))
    | (FromFloat(_), _) => Error(Other("Expected float, got something else"))
    }
    newFnCall->E.R2.fmap(run(~env))->OutputLocal.fromResult
  }
}

// See comment above GenericDist_Types.Constructors to explain the purpose of this module.
// I tried having another internal module called UsingDists, similar to how its done in
// GenericDist_Types.Constructors. However, this broke GenType for me, so beware.
module Constructors = {
  module C = GenericDist_Types.Constructors.UsingDists
  open OutputLocal
  let mean = (~env, dist) => C.mean(dist)->run(~env)->toFloatR
  let sample = (~env, dist) => C.sample(dist)->run(~env)->toFloatR
  let cdf = (~env, dist, f) => C.cdf(dist, f)->run(~env)->toFloatR
  let inv = (~env, dist, f) => C.inv(dist, f)->run(~env)->toFloatR
  let pdf = (~env, dist, f) => C.pdf(dist, f)->run(~env)->toFloatR
  let normalize = (~env, dist) => C.normalize(dist)->run(~env)->toDistR
  let toPointSet = (~env, dist) => C.toPointSet(dist)->run(~env)->toDistR
  let toSampleSet = (~env, dist, n) => C.toSampleSet(dist, n)->run(~env)->toDistR
  let truncate = (~env, dist, leftCutoff, rightCutoff) =>
    C.truncate(dist, leftCutoff, rightCutoff)->run(~env)->toDistR
  let inspect = (~env, dist) => C.inspect(dist)->run(~env)->toDistR
  let toString = (~env, dist) => C.toString(dist)->run(~env)->toStringR
  let toSparkline = (~env, dist, bucketCount) =>
    C.toSparkline(dist, bucketCount)->run(~env)->toStringR
  let algebraicAdd = (~env, dist1, dist2) => C.algebraicAdd(dist1, dist2)->run(~env)->toDistR
  let algebraicMultiply = (~env, dist1, dist2) =>
    C.algebraicMultiply(dist1, dist2)->run(~env)->toDistR
  let algebraicDivide = (~env, dist1, dist2) => C.algebraicDivide(dist1, dist2)->run(~env)->toDistR
  let algebraicSubtract = (~env, dist1, dist2) =>
    C.algebraicSubtract(dist1, dist2)->run(~env)->toDistR
  let algebraicLogarithm = (~env, dist1, dist2) =>
    C.algebraicLogarithm(dist1, dist2)->run(~env)->toDistR
  let algebraicPower = (~env, dist1, dist2) => C.algebraicPower(dist1, dist2)->run(~env)->toDistR
  let pointwiseAdd = (~env, dist1, dist2) => C.pointwiseAdd(dist1, dist2)->run(~env)->toDistR
  let pointwiseMultiply = (~env, dist1, dist2) =>
    C.pointwiseMultiply(dist1, dist2)->run(~env)->toDistR
  let pointwiseDivide = (~env, dist1, dist2) => C.pointwiseDivide(dist1, dist2)->run(~env)->toDistR
  let pointwiseSubtract = (~env, dist1, dist2) =>
    C.pointwiseSubtract(dist1, dist2)->run(~env)->toDistR
  let pointwiseLogarithm = (~env, dist1, dist2) =>
    C.pointwiseLogarithm(dist1, dist2)->run(~env)->toDistR
  let pointwisePower = (~env, dist1, dist2) => C.pointwisePower(dist1, dist2)->run(~env)->toDistR
}