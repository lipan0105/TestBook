# cinder-scheduler 与 DB 交互

---
## 参考代码示例

---
```
from cinder import context
from cinder import objects
from oslo_config import cfg

CONF = cfg.CONF
ctx = context.RequestContext("04b96562fac041678e8bdf9e91cc4000", "6498d2882b694f33bec9a73ca001db4b", True)

db_volume = {'status': 'available',
                     'host': 'controller@ceph',
                     'binary': 'cinder-volume',
                     'availability_zone': 'nova',
                     'attach_status': 'detached'}
updates=None
if updates:
    db_volume.update(updates)
from cinder.objects.volume import Volume
from oslo_db import options
connection = 'postgresql+psycopg2://admin-cinder:d6c3644a28d4Ti0*@192.168.109.2/cinder'
options.set_defaults(CONF, connection=connection)
volume = objects.Volume(context=ctx, **db_volume)
volume.create()
```

ctx传递参数user_id，project_id和is_admin_project为True，提供身份验证信息。 得到的结果如下：

```
{'service_user_domain_name': None, 'service_user_id': None, 'auth_token': None, '_user_domain_id': 
    None, 'resource_uuid': None, 'service_project_domain_name': None, 'read_only': False, 'service_token':  
    None, 'service_project_name': None, 'domain_name': None, 'is_admin_project': True, 'service_user_name': 
    None, 'user_name': None, 'user_domain_name': 
    None, '_user_id': '04b96562fac041678e8bdf9e91cc4000', 'project_domain_name': None, 'project_name': 
    None, 'global_request_id': None, 'service_project_id': None, 'timestamp': datetime.datetime(2019, 3, 6, 6, 38, 41, 
    213419), 'service_project_domain_id': None, 'remote_address': None, 'quota_class': None, '_domain_id': 
    None, 'is_admin': True, 'service_catalog': [], 'service_roles': [], 'show_deleted': False, 'roles': 
    ['admin'], 'service_user_domain_id': None, '_read_deleted': 'no', 'request_id': 'req-825ee911-f59c-421a-a816-
    35a09b94d083', '_project_id': '6498d2882b694f33bec9a73ca001db4b', '_project_domain_id': None}
```

`volume = objects.Volume(context=ctx, **db_volume)`

接着创建volume对象，较为关键。

```
def volume_create(context, values):
    """Create a volume from the values dictionary."""
    return IMPL.volume_create(context, values)
```

```
IMPL = oslo_db_api.DBAPI.from_config(conf=CONF,
                                     backend_mapping=_BACKEND_MAPPING,
                                     lazy=True)
```

`_BACKEND_MAPPING = {'sqlalchemy': 'cinder.db.sqlalchemy.api'}`

IMPL为一个DBAPI对象，该对象并不包含volume_create方法，因此会调用DBAPI对象的__getattr__方法。该方法会返回backend_name为"sqlalchemy“的可调用对象，调用该对象的volume_create方法。即调用‘cinder.db.sqlalchemy.api’的该方法。

```
def volume_create(context, values):
    values['volume_metadata'] = _metadata_refs(values.get('metadata'),
                                               models.VolumeMetadata)
    if is_admin_context(context):
        values['volume_admin_metadata'] = \
            _metadata_refs(values.get('admin_metadata'),
                           models.VolumeAdminMetadata)
    elif values.get('volume_admin_metadata'):
        del values['volume_admin_metadata']

    volume_ref = models.Volume()
    if not values.get('id'):
        values['id'] = str(uuid.uuid4())
    volume_ref.update(values)

    session = get_session()
    with session.begin():
        session.add(volume_ref)

    return _volume_get(context, values['id'], session=session)
```

将values的值赋值给volume_ref，进行数据库数据的插入。




