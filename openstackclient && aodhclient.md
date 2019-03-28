1.openstack alarm list 与aodh alarm list执行的步骤有何不同?
2.在过滤endpoint时，参数interface为internal是何时注入与生效的?


执行openstack alarm list的流程：
openstack alarm list 调用openstackclient/shell.py
```
def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
        if six.PY2:
            # Emulate Py3, decode argv into Unicode based on locale so that
            # commands always see arguments as text instead of binary data
            encoding = locale.getpreferredencoding()
            if encoding:
                argv = map(lambda arg: arg.decode(encoding), argv)

    return OpenStackShell().run(argv)
```
调用父类cliff的app.py的run函数，其中会调用initialize_app方法。
```
self.client_manager = clientmanager.ClientManager(
            cli_options=self.cloud,
            api_version=self.api_version,
            pw_func=shell.prompt_for_password,
        )
```
这里会初始化一个client_manager用于创建aodhclient.aodhclient作为插件是通过stevedore加载的。
```
    def _load_plugins(self):
        """Load plugins via stevedore

        osc-lib has no opinion on what plugins should be loaded
        """
        # Loop through extensions to get API versions
        for mod in clientmanager.PLUGIN_MODULES:
            default_version = getattr(mod, 'DEFAULT_API_VERSION', None)
            # Only replace the first instance of "os", some service names will
            # have "os" in their name, like: "antiddos"
            option = mod.API_VERSION_OPTION.replace('os_', '', 1)
            version_opt = str(self.cloud.config.get(option, default_version))
        ......
    # openstackclient/common/clientmanager.py中定义加载的插件
    # Append list of external plugin modules
PLUGIN_MODULES.extend(get_plugin_modules(
    'openstack.cli.extension',
))
```
加载client插件：
```
def get_plugin_modules(group):
    #group为openstack.cli.extension
    """Find plugin entry points"""
    mod_list = []
    #aodhclient对应的entry_points为openstack.cli.extension：
    #metric = aodhclient.osc
    for ep in pkg_resources.iter_entry_points(group):
        LOG.debug('Found plugin %s', ep.name)

        try:
            __import__(ep.module_name)
        except Exception:
            sys.stderr.write(
                "WARNING: Failed to import plugin %s.\n" % ep.name)
            continue

        module = sys.modules[ep.module_name]
        mod_list.append(module)
        init_func = getattr(module, 'Initialize', None)
        if init_func:
            init_func('x')

        # Add the plugin to the ClientManager
        #osc.py中定义了API_NAME = "alarming"
        # 为clientManager添加了名：alarming，值为：make_client方法返回的对象
        setattr(
            clientmanager.ClientManager,
            module.API_NAME,
            clientmanager.ClientCache(
                getattr(sys.modules[ep.module_name], 'make_client', None)
            ),
        )
    return mod_list
```
make_client方法体为：
```
def make_client(instance):
    """Returns an queues service client."""
    version = instance._api_version[API_NAME]
    try:
        version = int(version)
    except ValueError:
        version = float(version)

    aodh_client = utils.get_client_class(
        API_NAME,
        version,
        API_VERSIONS)
    # NOTE(sileht): ensure setup of the session is done
    instance.setup_auth()
    return aodh_client(session=instance.session)
```
该方法会初始化一个aodhclient，具体调用的是aodhclient.v2.client.Client.
### ps：当环境变量指定了使用internal endpoint访问服务时，代码最终却走的是public endpoint，原因是初始化client时，interface=‘internal’参数未传递。（对应问题2的解决）修改client初始化即可：
```return aodh_client(session=instance.session, interface=instance._interface)```
下面为client初始化：
```
class Client(object):
    """Client for the Aodh v2 API.

    :param string session: session
    :type session: :py:class:`keystoneauth.adapter.Adapter`
    """

    def __init__(self, session=None, service_type='alarming', **kwargs):
        """Initialize a new client for the Aodh v2 API."""
        self.api = client.SessionClient(session, service_type=service_type,
                                        **kwargs)
        self.alarm = alarm.AlarmManager(self)
        self.alarm_history = alarm_history.AlarmHistoryManager(self)
        self.capabilities = capabilities.CapabilitiesManager(self)
```
至此，openstackclient初始化aodhclient完成。
接着我们从命令openstack alarm list如何被解析和执行来梳理整个流程。
alarm list会解析至： ```alarm list = aodhclient.v2.alarm_cli:CliAlarmList```

```
class CliAlarmList(lister.Lister):
    """List alarms"""
    ......

    def take_action(self, parsed_args):
        if parsed_args.query:
            if any([parsed_args.limit, parsed_args.sort, parsed_args.marker]):
                raise exceptions.CommandError(
                    "Query and pagination options are mutually "
                    "exclusive.")
            query = jsonutils.dumps(
                utils.search_query_builder(parsed_args.query))
            alarms = utils.get_client(self).alarm.query(query=query)
        else:
            filters = dict(parsed_args.filter) if parsed_args.filter else None
            alarms = utils.get_client(self).alarm.list(
                filters=filters, sorts=parsed_args.sort,
                limit=parsed_args.limit, marker=parsed_args.marker)
        return utils.list2cols(ALARM_LIST_COLS, alarms)
```
在util.py中会对client进行判断是openstackclient还是aodhclient发起的调用。
```
#该函数解决了openstackclient和aodhclient实现的不同
def get_client(obj):
    #如果是openstackclient发起的请求，进入if
    if hasattr(obj.app, 'client_manager'):
        # NOTE(liusheng): cliff objects loaded by OSC
        return obj.app.client_manager.alarming
    #如果是aodhclient发起的请求，进入else
    else:
        # TODO(liusheng): Remove this when OSC is able
        # to install the aodh client binary itself
        return obj.app.client
```
openstackclient在/v2/client.py的初始化client并调用对应的api. aodhclient会在shell.py中初始化client，对应的代码如下：
```
@property
    def client(self):
        # NOTE(sileht): we lazy load the client to not
        # load/connect auth stuffs
        if self._client is None:
            if hasattr(self.options, "endpoint"):
                endpoint_override = self.options.endpoint
            else:
                endpoint_override = None
            auth_plugin = loading.load_auth_from_argparse_arguments(
                self.options)
            session = loading.load_session_from_argparse_arguments(
                self.options, auth=auth_plugin)

            self._client = client.Client(self.options.aodh_api_version,
                                         session=session,
                                         interface=self.options.interface,
                                         region_name=self.options.region_name,
                                         endpoint_override=endpoint_override)
        return self._client
```

此时也会调用到aodhclient.v2.client模块中，加载client.注意aodhclient初始化传递了interface参数，因此环境变量里的interface值可被正常获取并传递（对应问题2的解决）。

参考：
https://pypi.org/project/python-cliclient/1.0.0/ 创建一个自用的client plugin