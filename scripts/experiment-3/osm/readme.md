# Phase 0: Scheduling action

Phase 0 Scheduling starts when the user initiates the ns-create call and ends when the pod in the 'osm' namespace with the 'app.kubernetes.io/component=lcm' label logs the following:

```
2026-08-26T14:30:11 INFO lcm.ns lcm_utils.py:224 Desc: {'_admin.nslcmop': 'db70fb34-d682-4ccb-af90-eda32d4449ea', '_admin.current-operation': 'db70fb34-d682-4ccb-af90-eda32d4449ea', '_admin.operation-type': 'RUNNING ACTION', 'currentOperation': 'RUNNING ACTION', 'currentOperationID': 'db70fb34-d682-4ccb-af90-eda32d4449ea', 'errorDescription': None, 'errorDetail': None, '_admin.modified': 1787754611.6091115} Item: nsrs _id: 13cb134c-1aec-433f-aa7c-aa45b55250d5
```

To avoid confusions, the timestamp of the message should be after the user initiates the ns-create call. The moment this message is found, then we take the timestamp of this message to initiate phase 1.

# Phase 1: Upgrade

Phase 0 ends when the pod in the 'osm' namespace with the 'app.kubernetes.io/component=lcm' label logs the following:

```
2026-08-26T14:30:29 INFO lcm.ns lcm_utils.py:224 Desc: {'detailed-status': 2, 'queuePosition': 0, 'stage': '', 'errorMessage': '', 'operationState': 'COMPLETED', 'statusEnteredTime': 1787754629.4479592, '_admin.modified': 1787754629.4479616} Item: nslcmops _id: db70fb34-d682-4ccb-af90-eda32d4449ea
```
Where `<TIMESTAMP>` is in 2026-08-25T19:43:41 format

