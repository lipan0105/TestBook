##Tempest学习心得
---------------------------
---------------------------
针对计量组件目前的tempest测试用例空缺的状态，用了将近一个月时间，我对如何写tempest用例以及如何将测试通过的用例添加到已有的生产环境中进行了学习。这里，对整体所学做一个总结输出。
<br/>

* 第一步：安装tempest模块，按照官方教程即可。期间碰到某几个模块不能成功安装，应该是网速的原因，解决方法是在requirements.txt将未安装的依赖包注释掉，使用pip命令直接指定具体的包以及版本号安装即可。
* 第二步：创建tempest工作空间。该步骤的作用是，可以通过在不同的工作空间中配置不同的云环境信息，从而达到测试多套云环境的目标。我要测试的云环境只有组内的云环境，因此省略了该步骤。
* 第三步：配置tempest.conf文件。该步骤用于配置待测试的云环境信息。包括配置auth段信息，用于访问云环境；开启将要测试的服务，默认所有的服务都是开启的，如果只想测试某个服务，则将其他服务设置为false;除此之外，如果测试nova创建虚拟机，则需要给定镜像和规格，并且相应的开启所依赖的网络服务。
* 第四步：运行具体的测试用例。使用的命令如下：
    * tempest run -r test_telemetry_notification_api --workspace cloud-01
    * ostestr --pdb  tempest.api.compute.servers.test_create_server
    进入到测试目录下，指定要测试的模块和测试用例，运行即可。若测试用例中含有断点，用命令2测试有效。
*  第五步：查看测试结果并记录用于下一阶段调试，结束该测试流程。

上面这五个步骤就是执行tempest测试用例的大致过程，这里针对如何写测试用例，并将其加入tempest模块进行正常测试进行展开描述。

我编写的第一个测试用例场景是：当一个虚拟机创建完成后，其对应的监控资源也应该创建妥当，通过访问gnocchi服务可以查询到该虚拟机对应的监控资源，并且包含两条监控资源信息：instance resource和network resource.
在该测试用例中，实现的第一步骤是创建网络，接着创建虚拟机，接着调用gnocchi API接口查询对应得资源信息。其中网络和虚拟机的创建直接调用已有tempest模块中的相关clients发送请求即可完成创建流程。而用于向gnocchi发送restful请求的clients则需要自行构造完成。下面是该测试用例：

```js:test function
def test_create_server_before_ceilometer(self):
        net1 = self._create_net_subnet_ret_net_from_cidr('19.80.0.0/24')
        networks = [{'uuid': net1['network']['id']}]
        server = self.create_test_server(networks=networks,wait_until='ACTIVE')
        time.sleep(120)
        status = self.resource_client.search_resource_by_vm_id(server['id'])
        if status=="200":
            self.assertTrue(status)
```

调用resource_client的查询方法，获取返回的状态码进行校验。

```js:resource client
class ResourceClient(rest_client.RestClient):
    def search_resource_by_vm_id(self,vm_id):
        url = "v1/search/resource/generic?"
        query = {"like": {"original_resource_id": "%%%%%s%%%%"%vm_id}}
        post_body = json.dumps(query)
        resp, body = self.post(url,post_body)
        body=json.loads(body)
        for resource in body:
            rest_client.ResponseBody(resp, resource)
        if len(body)==2:
            return resp.status
```

resource_client构造相应的restful请求并选择post方法发送请求。值得注意的是，tempest的所有client都继承了rest_client.Restclient类，该类实现了具体的http请求的发送与接收。这个类是公共类，只需要继承使用即可。接收到http返回结果后，对body内容进行分析，若其中包含两条监控资源信息时，则返回”200”成功状态码，表明该测试通过。在测试用例的的添加正确断言表示该测试运行的结果为ok.

---------------------

到这里一个测试用例就执行完毕了。值得强调的是，tempest有自行一套的运行流程，先找到需要测试的测试文件，然后完成测试用例执行前的准备工作，例如加载配置文件，加载所需的client，创建安全组，用户，工程，分配角色等等，在测试用例执行完成后，也会做一些资源销毁工作，删除本次测试所创建的资源，包括虚拟机，网络等等。
其实tempest是基于python的单元测试模块所开发的，只是多出些云环境测试的特性而已。例如在setUpClass()中，会包含四个步骤：

   * skip_checks  //检查是否需要跳过该测试
   * - setup_credentials //校验鉴权信息是否通过
   * - setup_clients  //加载所需的client类
   * - resource_setup //准备所需的资源

同样在tearDownClass()中也会执行clear_credentials/resource_cleanup这些步骤。
这里对加载client类这一步骤稍作展开。因为gnocchi组件的tempest client是新添加的，因此需要在在测试进行之前，对该client类进行注册，这样后面的测试用例才能正常调用。这涉及到几个文件的修改：clients.py中注册gnocchi模块的resource_client，并在头部引入该clients所在路径。在services/clients.py里的tempest_modules()方法中引入gnocchi服务，并提供服务对应模块所在路径。在services/gnocchi的__init__.py中引入gnocchi服务所有的client.

----------
----------
到这里，关于如何添加tempest测试用例的流程已经大致介绍完毕。该过程遇到的问题很多，总结下来大致有两点：（1）python编程基础不够扎实，会碰上方法调用无效的问题，大多是因为名称写错导致；
（2）由于生产环境中的tempest模块在持续更新中，因此会出现更新了tempest版本，测试用例不能通过的现象。这是因为gnocchi测试用例依赖nova创建虚拟机和neutron创建网络模块。该部分代码若是有所改变，应该在gnocchi中做出相应改变，负责测试理所当然不能通过。这种gnocchi与其他模块的高耦合性对后期测试用例的维护工作带来了不小的困难。