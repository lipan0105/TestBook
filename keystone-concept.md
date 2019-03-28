## keystone 入门级思考

user,project,domain,role 形成的以用户为中心的组合关系。

| user | project | role |
|--------|--------| -------- |
|    value    |   /     |    /    |
|    value    |   value     |    /    |
|    value    |   value     |    value    |


按照每行规定的user信息，执行openstack token issue和openstack project list命令，结果有：

+ 行3为常见情形，执行命令均正常
+ 行2未给用户分配角色，token issue正常执行，但是无法执行第2个命令。
+ 行1正常创建用户指定domain_id，不分配project. 结果是命令一正常执行，命令二由于catalog信息缺失导致获得project时，无权限。

总结发现，不分配project的用户，能正常获得token，但是scope信息的缺失导致token_data的catalog和role为空，因此无法访问其他服务。

问题记录：
keystoneclient中auth/identity/v3/base.py 的get_auth_ref（）方法中，记录了如何将scope信息注入request中。
3.13日计划将打印body中的数据，查看scope是否包含

