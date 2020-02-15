module Internals = {
  [@bs.deriving abstract]
  type discrete = {
    xs: array(float),
    ys: array(float),
  };

  let jsToDistDiscrete = (d: discrete): DistributionTypes.discreteShape => {
    xs: xsGet(d),
    ys: ysGet(d),
  };

  [@bs.deriving abstract]
  type combined = {
    continuous: CdfLibrary.JS.distJs,
    discrete,
  };

  let toContinous = (r: combined): DistributionTypes.continuousShape =>
    continuousGet(r) |> CdfLibrary.JS.jsToDist;
  let toDiscrete = (r: combined): DistributionTypes.discreteShape =>
    discreteGet(r) |> jsToDistDiscrete;

  [@bs.module "./GuesstimatorLibrary.js"]
  external toCombinedFormat: (string, int) => combined = "run";

  let toMixedShape = (r: combined): option(DistributionTypes.mixedShape) => {
    let assumptions: Shape.Mixed.Builder.assumptions = {
      continuous: ADDS_TO_1,
      discrete: ADDS_TO_CORRECT_PROBABILITY,
      discreteProbabilityMass: Some(0.3),
    };
    Shape.Mixed.Builder.build(
      ~continuous=toContinous(r),
      ~discrete=toDiscrete(r),
      ~assumptions,
    );
  };
};

let stringToMixedShape = (~string, ~sampleCount=1000, ()) =>
  Internals.toCombinedFormat(string, sampleCount) |> Internals.toMixedShape;