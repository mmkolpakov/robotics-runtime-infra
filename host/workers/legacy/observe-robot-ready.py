#!/usr/bin/env python3
"""Finite legacy Clock, exact zero JointState and TF readiness gate."""
import argparse
import json
import time
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile,ReliabilityPolicy
from rosgraph_msgs.msg import Clock
from sensor_msgs.msg import JointState
from tf2_msgs.msg import TFMessage
parser=argparse.ArgumentParser();parser.add_argument('--after-ns',required=True,type=int);cursor=parser.parse_args().after_ns
if cursor<0:raise ValueError('native Clock cursor cannot be negative')
rclpy.init();node=Node('legacy_robot_readiness_probe');observed={}
qos=QoSProfile(depth=1000,reliability=ReliabilityPolicy.RELIABLE)
def clock(m):
 stamp=m.clock.sec*1_000_000_000+m.clock.nanosec
 if stamp>cursor:observed['clock']={'ns':str(stamp)}
def joint(m):
 stamp=m.header.stamp.sec*1_000_000_000+m.header.stamp.nanosec
 if list(m.name)==['slider_joint'] and list(m.position)==[0.0] and stamp>cursor:observed['joint_state']={'name':list(m.name),'position':list(m.position),'stamp_ns':str(stamp)}
def tf(m):
 for t in m.transforms:
  p,q=t.transform.translation,t.transform.rotation;stamp=t.header.stamp.sec*1_000_000_000+t.header.stamp.nanosec
  if t.header.frame_id=='base_link' and t.child_frame_id=='slider_link' and (p.x,p.y,p.z,q.x,q.y,q.z,q.w)==(0.2,0.0,0.0,0.0,0.0,0.0,1.0) and stamp>cursor:observed['tf']={'parent':t.header.frame_id,'child':t.child_frame_id,'translation':[p.x,p.y,p.z],'rotation':[q.x,q.y,q.z,q.w],'stamp_ns':str(stamp)}
node.create_subscription(Clock,'/clock',clock,qos);node.create_subscription(JointState,'/joint_states',joint,qos);node.create_subscription(TFMessage,'/tf',tf,qos)
try:
 deadline=time.monotonic()+85
 while time.monotonic()<deadline and len(observed)<3:rclpy.spin_once(node,timeout_sec=0.05)
 if len(observed)!=3:raise RuntimeError('native robot readiness missing: '+','.join(sorted({'clock','joint_state','tf'}-set(observed))))
 print(json.dumps({'status':'passed','after_ns':str(cursor),'observed':observed}))
finally:node.destroy_node();rclpy.shutdown()
