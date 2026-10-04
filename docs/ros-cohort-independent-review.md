# Stock ROS source qualification

The neutral SOURCE run on stock ros_gz_sim 1.0.24 / interfaces 1.5.1 passed native
asset/canonical ordering, exact stepping, fresh Clock/JointState/TF, original LIVE,
recording/finalization and guarded cleanup. After source storage removal, a
read-only consumer verified all 361 completion/resource references by hash and size.
The reader's own project cleanup was also empty.

A separate fresh scene used imported native interface constants and observed
request, response and effect. SCOPE_TIME returned FEATURE_UNSUPPORTED, preserving
clock/state/model. SCOPE_ALL returned RESULT_OK, reset Clock to zero and removed
the dynamically spawned model from successful GetEntities output.
Initial and final state were PLAYING; a separate pause produced PAUSED and
quiescent Clock. Reset does not promise to preserve PAUSED.

The removed model's GetEntityState returned OPERATION_FAILED with its original
diagnostic. Absence is proved through successful GetEntities, not an inferred
error-code translation. Earlier failed assumptions and raw results remain retained.

[The evidence index](proofs/ros-cohort-independent-review.json) binds native
requests/responses, state, entities, exact byte references and cleanup observations.
The original positive scene and immutable R10 were untouched.
Released B3 and broader legacy CLI equivalence remain separate gates.
