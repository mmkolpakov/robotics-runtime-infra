# Playback fixture

`golden/` is a ROS 2 Jazzy MCAP bag containing 40
`std_msgs/msg/Int32` messages on `/playback_probe`.

The fixture is intentionally small. It verifies clocked playback and DDS
delivery without coupling the infrastructure repository to a robot, camera,
model, or business scenario.
