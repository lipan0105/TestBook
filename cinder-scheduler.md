---

#cinder-scheduler筛选流程

---
核心代码

```
    def schedule_create_volume(self, context, request_spec, filter_properties):
        backend = self._schedule(context, request_spec, filter_properties)

        if not backend:
            raise exception.NoValidBackend(reason=_("No weighed backends "
                                                    "available"))

        backend = backend.obj
        volume_id = request_spec['volume_id']

        updated_volume = driver.volume_update_db(context, volume_id,
                                                 backend.host,
                                                 backend.cluster_name)
        self._post_select_populate_filter_properties(filter_properties,
                                                     backend)

        # context is not serializable
        filter_properties.pop('context', None)

        self.volume_rpcapi.create_volume(context, updated_volume, request_spec,
                                         filter_properties,
                                         allow_reschedule=True)
```

命令行为：openstack --debug volume create --size 1 --type nova_ceph test_lp_001
结果如下：

```
+---------------------+--------------------------------------+
| Field               | Value                                |
+---------------------+--------------------------------------+
| attachments         | []                                   |
| availability_zone   | nova                                 |
| backend_type        | CEPH                                 |
| bootable            | false                                |
| consistencygroup_id | None                                 |
| created_at          | 2019-03-08T01:09:04.677899           |
| description         | None                                 |
| encrypted           | False                                |
| id                  | c734763c-bad6-459c-b916-3915704a5d00 |
| migration_status    | None                                 |
| multiattach         | False                                |
| name                | test_lp_001                          |
| properties          | volume_az='nova'                     |
| replication_status  | None                                 |
| size                | 1                                    |
| snapshot_id         | None                                 |
| source_volid        | None                                 |
| status              | creating                             |
| total_backup        | 0                                    |
| total_snap          | 0                                    |
| type                | nova_ceph                            |
| updated_at          | None                                 |
| user_id             | 04b96562fac041678e8bdf9e91cc4000     |
+---------------------+--------------------------------------+

```

参数request_spec为：
```
CG_backend=<?>,cgsnapshot_id=None,consistencygroup_id=None,group_backend=<?>,group_id=None,image_id=None,snapshot_id=None,source_replicaid=None,source_volid=None,volume=Volume(c734763c-bad6-459c-b916-3915704a5d00),volume_id=c734763c-bad6-459c-b916-3915704a5d00,volume_properties=VolumeProperties,volume_type=VolumeType(a9b5aadc-18eb-497b-b8a5-1ef00f2dfa66)
```


volume_properties值为：
```

{'_obj_display_name': u'test_lp_002', '_context': <cinder.context.RequestContext object at 0x7f9e49159450>, '_obj_consistencygroup_id': None, '_obj_attach_status': u'detached', '_obj_reservations': [u'23318fd5-74c0-4068-b7c8-f21afba32816', u'a150fec8-a99f-48ef-b8be-ea9906057374', u'754a77dd-a07a-4576-825f-80e3e380dde9', u'870bbed1-a900-4c25-b751-3217f7ed9b99'], '_obj_status': u'creating', '_obj_source_replicaid': None, '_changed_fields': set([u'status', u'volume_type_id', u'snapshot_id', u'display_name', u'multiattach', u'reservations', u'availability_zone', u'attach_status', u'source_volid', u'cgsnapshot_id', u'project_id', u'qos_specs', u'encryption_key_id', u'display_description', u'source_replicaid', u'user_id', u'group_id', u'consistencygroup_id', u'size', u'metadata']), '_obj_cgsnapshot_id': None, '_obj_metadata': {u'volume_az': u'nova'}, '_obj_user_id': u'04b96562fac041678e8bdf9e91cc4000', '_obj_project_id': u'6498d2882b694f33bec9a73ca001db4b', '_obj_qos_specs': None, '_obj_availability_zone': u'nova', '_obj_display_description': None, 'VERSION': u'1.1', '_obj_volume_type_id': 'a9b5aadc-18eb-497b-b8a5-1ef00f2dfa66', '_obj_snapshot_id': None, '_obj_encryption_key_id': None, '_obj_source_volid': None, '_obj_group_id': None, '_obj_multiattach': False, '_obj_size': 1}
```
其中volumeproperties为volume_az='nova'. filter_properties为空

进入_get_weighted_candidates方法，该方法是选出volume将要被创建的节点。self._populate_retry（）方法会默认尝试scheduler 3 次，如果失败则抛出异常。


方法中会更新filter_properties字段，resource_type等于volume_type，值为nova_ceph.

```
filter_properties.update({'context': context,
                                  'request_spec': request_spec_dict,
                                  'config_options': config_options,
                                  'volume_type': volume_type,
                                  'resource_type': resource_type})
```


接着取出request_spec值更新 filter_properties.

```
 vol = request_spec['volume_properties']
        filter_properties['size'] = vol['size']
        filter_properties['availability_zone'] = vol.get('availability_zone')
        filter_properties['user_id'] = vol.get('user_id')
        filter_properties['metadata'] = vol.get('metadata')
        filter_properties['qos_specs'] = vol.get('qos_specs')
```

获取所有的可支持后端：get_all_backend_states（）

执行 cluster.mon_command('{"prefix":"df", "format":"json"}', '')与monitor交互，得到存储池cinder-volumes空闲和总容量，单位为GB.

举例结果如下：
```

(0, '{"stats":{"total_bytes":1277126737920,"total_used_bytes":11941257216,"total_avail_bytes":1265185480704},"pools":[{"name":"rbd","id":0,"stats":{"kb_used":1,"bytes_used":51,"max_avail":598634189379,"objects":5}},{"name":"cinder-volumes","id":1,"stats":{"kb_used":2455981,"bytes_used":2514923732,"max_avail":598634189379,"objects":637}},{"name":"images","id":2,"stats":{"kb_used":5283043,"bytes_used":5409835552,"max_avail":598634189379,"objects":650}},{"name":"ephemeral","id":3,"stats":{"kb_used":0,"bytes_used":0,"max_avail":598634189379,"objects":0}},{"name":"default.rgw.buckets.data","id":4,"stats":{"kb_used":0,"bytes_used":0,"max_avail":598634189379,"objects":0}}]}\n', u'')
```

第一个值0表示能正常获取该存储池数据保存状况，非0表示不可知。
如此获得的*capabilities*取值示例为：

```
stats = {
            'vendor_name': 'Open Source',
            'driver_version': self.VERSION,
            'storage_protocol': 'ceph',
            'total_capacity_gb': '数值',
            'free_capacity_gb': '数值',
            'reserved_percentage': (
                self.configuration.safe_get('reserved_percentage')),
            'multiattach': True,
            'thin_provisioning_support': True,
            'max_over_subscription_ratio': (
                self.configuration.safe_get('max_over_subscription_ratio'))，
           ''volume_backend_name'': 'ceph',
           'replication_enabled': False,
           
          

        }
```

参数'thin_provisioning_support'定义是否支持瘦分配，即用多少算多少，而不是直接划分所分配的容量大小等待使用。也称为精简配置。
provisioned_capacity 预留容量，max_over_subscription_ratio存储超分比。reserved_percentage预留容量比例。

```
backends = self.host_manager.get_all_backend_states(elevated)
backends = self.host_manager.get_filtered_backends(backends,
                                                           filter_properties)
```

先选出所有可用的backends, 接着获取filter backends. 配置文件中设置的filter为：
scheduler_default_filters=AvailabilityZoneFilter,CapacityFilter,CapabilitiesFilter
意味着，过滤可用的存储后端会依次按照上面的顺序进行filter.

` weighed_backends = self.host_manager.get_weighed_backends(backends, filter_properties)`

对上面经过筛选的backends进行权重赋值。默认使用的weighter插件为CapacityWeigher,可进行自由配置。对赋予权重的backends按照weight值从大到小排序，取出第一个backend，创建volume。流程进入cinder-volume。





###疑问：
1. 筛选节点时，为何要给当前用户添加admin角色，升级用户？
  是否是由于执行cinder service-list的权限只有admin角色有，已验证

 验证过程，使用角色为__member__的用户，执行cinder service-list出现结果如下：

 *ERROR: Policy doesn't allow volume_extension:services:index to be performed. (HTTP 403) (Request-ID: req-483b0e99-e529-436c-b0cd-932b1af90ac4)*

结合cinder工程的policy.json可对比验证：
*"volume_extension:services:index": "rule:admin_api"*






###知识点记录：
####1. python 关于文件相关时间操作

+ #输出最近访问时间os.path.getctime(file)
+ #输出文件创建时间os.path.getmtime(file)
+ #输出最近修改时间time.gmtime(os.path.getmtime(file))
+ #以struct_time形式输出最近修改时间os.path.getsize(file)
+ #输出文件大小（字节为单位）os.path.abspath(file)
+ #输出绝对路径'/Volumes/Leopard/Users/Caroline/Desktop/1.mp4'os.path.normpath(file)

####2. 备注
读写rbd实例

```
import rados
import pdb
try:
    cluster = rados.Rados(conffile='/etc/ceph/ceph.conf')
except Exception as e:
    print 'Argumen', e

print "Created cluster handle."

try:
    cluster.connect()
    print "try inner"
except Exception as e:
    print "connection error: ", e
    raise e
finally:
    print "Connected to the cluster."

print "\n\nI/O Context and Object Operations"
print "================================="

print "\nCreating a context for the 'data' pool"
if not cluster.pool_exists('rbd'):
        raise RuntimeError('No rbd pool exists')
ioctx = cluster.open_ioctx('rbd')

print "\nWriting object 'hw' with contents 'Hello World!' to pool 'data'."
ioctx.write("hw", "Hello World!")
print "Writing XATTR 'lang' with value 'en_US' to object 'hw'"
ioctx.set_xattr("hw", "lang", "en_US")


print "\nWriting object 'bm' with contents 'Bonjour tout le monde!' to pool 'data'."
ioctx.write("bm", "Bonjour tout le monde!")
print "Writing XATTR 'lang' with value 'fr_FR' to object 'bm'"
ioctx.set_xattr("bm", "lang", "fr_FR")

print "\nContents of object 'hw'\n------------------------"
print ioctx.read("hw")

print "\n\nGetting XATTR 'lang' from object 'hw'"
print ioctx.get_xattr("hw", "lang")

print "\nContents of object 'bm'\n------------------------"
print ioctx.read("bm")

print "Getting XATTR 'lang' from object 'bm'"
print ioctx.get_xattr("bm", "lang")


object_iterator = ioctx.list_objects()
while True :
    try :
        rados_object = object_iterator.next()
        print "Object contents = " + rados_object.read()
    except StopIteration :
            break

print "Removing object 'hw'"
#ioctx.remove_object("hw")
print "Removing object 'bm'"
#ioctx.remove_object("bm")

print "\nClosing the connection."
ioctx.close()

print "Shutting down the handle."
cluster.shutdown()

```






