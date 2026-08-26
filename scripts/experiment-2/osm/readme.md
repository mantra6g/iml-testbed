# Phase 0: Scheduling

Phase 0 Scheduling starts when the user initiates the ns-create call and ends when the pod in the 'osm' namespace with the 'app.kubernetes.io/component=lcm' label logs the following:

```
2026-08-25T19:43:37 INFO lcm.ns lcm_utils.py:224 Desc: {'queuePosition': 0, 'stage': 'Stage 1/5: preparation of the environment.', 'detailed-status': 'Stage 1/5: preparation of the environment. Reading from database. ', '_admin.modified': 1787687017.8030634} Item: nslcmops _id: ced44d8c-f85a-450f-92e4-7b45ac910ffd
```

To avoid confusions, the timestamp of the message should be after the user initiates the ns-create call. The moment this message is found, then we take the timestamp of this message to initiate phase 1.

# Phase 1: Deployment Pre-steps

Phase 0 ends when the pod in the 'osm' namespace with the 'app.kubernetes.io/component=lcm' label logs the following:

```
<TIMESTAMP> INFO lcm.ns lcm_utils.py:224 Desc: {'detailed-status': 'Stage 2/5: deployment of KDUs, VMs and execution environments. 0/2. ', '_admin.modified': 1787687021.0620408} Item: nsrs _id: <UUID-2>
```
Where `<TIMESTAMP>` is in 2026-08-25T19:43:41 format

# Phase 2: Deployment at VIM

During this phase, multiple logs can be found:

```
<TIMESTAMP> INFO lcm.ns lcm_utils.py:224 Desc: {'detailed-status': 'Stage 2/5: deployment of KDUs, VMs and execution environments. 0/2. VIM: (progress 0/X)', '_admin.modified': 1787687021.0620408} Item: nsrs _id: <UUID-2>

<TIMESTAMP> INFO lcm.ns lcm_utils.py:224 Desc: {'_admin.deployed.RO.operational-status': 'running', 'detailed-status': 'Stage 2/5: deployment of KDUs, VMs and execution environments. 1/2. Deployed at VIM', '_admin.modified': 1787687051.1518774} Item: nsrs _id: <UUID-2>

<TIMESTAMP> INFO lcm.ns lcm_utils.py:224 Desc: {'queuePosition': 0, 'stage': 'Stage 2/5: deployment of KDUs, VMs and execution environments.', 'detailed-status': 'Stage 2/5: deployment of KDUs, VMs and execution environments. 2/2. Deployed at VIM', '_admin.modified': 1787687051.2248583} Item: nslcmops _id: <UUID-2>
```

# Done

Finally, phase 2 is finished and deployment is done whenever this log is found:

```
<TIMESTAMP> DEBUG lcm.ns ns.py:4893 Task ns=<UUID-1> instantiate=<UUID-2> Deploying at VIM: Done
```

