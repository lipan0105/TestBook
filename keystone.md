带着一下问题学习keystone：

+ 为什么"Scoping to both domain and project is not allowed“
+ catalog信息，导致该用户无法执行任何操作？ 背景及其原因的探讨
   + token_data存放catalog信息，token_id存放重点的如project等信息，缘由是token_id在header中，长度受限，而catalog存放于token_data并注入body体进行返回。
+ 非project 的scope无法获得catalog信息？打印出token data数据即可验证
    + reproduce:  创建一个用户不指定所属project只是指定domain，并分配角色为admin，为和返回的token_data不包含service 
    + 原因总结：由于传递过来的参数auth被client处理之后，就不包含scope信息，因此得到的scope_data为空，因此无法取到相应的catalog。
+ audit_ids字段的作用


+ 问题2：在auth/controllers.py得到的token_id为：

`gAAAAABchwwhy1N9dtJa2Vuuqi2GnhtayqWmtKmAGXs_Wo7OhHAz7ED9EGesMgLmLG8UnJgi9U2vRwJUU-VGCguJT468Jm6ypuXOO-j6wHa1YJGlUV0-fFDGBDRSZkeSZ3MhEuEiRF30cxLm_vdM0mevGiRg06HYjA`

token_data为：

`{'token': {'issued_at': '2019-03-12T01:32:17.000000Z', 'audit_ids': [u'OL0gFA5VSpWRiXPs0D_IwQ'], 'methods': [u'password'], 'expires_at': '2019-03-12T02:32:17.000000Z', 'user': {'password_expires_at': None, 'domain': {'id': u'default', 'name': u'Default'}, 'id': u'a6336d1c41114874bfdb2d2bae52a3fe', 'name': u'test_3_11'}}}`

此处获得的token_data已不包含catalog值。方法主体为：

```
    def authenticate_for_token(self, request, auth=None):
        """Authenticate user and issue a token."""
        # include_catalog=True
        include_catalog = 'nocatalog' not in request.params

       #校验auth信息格式是否合法
        validate_issue_token_auth(auth)

        try:
            #初始化auth_info信息，包含auth和auth_data=（None,None,None,None）
            auth_info = core.AuthInfo.create(auth=auth)
            auth_context = core.AuthContext(extras={},
                                            method_names=[],
                                            bind={})
            #auth_context返回值为：{'bind': {}, 'extras': {}, 'method_names': []}
           #将传递的auth信息使用验证插件进行用户信息有效性校验，这里插件为password.
           #方法会为auth_context注入通过验证的user_id和method字段信息
            self.authenticate(request, auth_info, auth_context)
            #如果验证插件为oauth1,则包含access_token_id
            if auth_context.get('access_token_id'):
                auth_info.set_scope(None, auth_context['project_id'], None)
            #该方法用于设置scope信息
            self._check_and_set_default_scoping(auth_info, auth_context)
            #获得_scope_data=(None,None,None,None)
            (domain_id, project_id, trust, unscoped) = auth_info.get_scope()

            # NOTE(notmorgan): only methods that actually run and succeed will
            # be in the auth_context['method_names'] list. Do not blindly take
            # the values from auth_info, look at the authoritative values. Make
            # sure the set is unique.
            method_names_set = set(auth_context.get('method_names', []))
            #method name赋值为password
            method_names = list(method_names_set)

            # Do MFA Rule Validation for the user
            if not self._mfa_rules_validator.check_auth_methods_against_rules(
                    auth_context['user_id'], method_names_set):
                raise exception.InsufficientAuthMethods(
                    user_id=auth_context['user_id'],
                    methods='[%s]' % ','.join(auth_info.get_method_names()))

            expires_at = auth_context.get('expires_at')
            token_audit_id = auth_context.get('audit_id')

            is_domain = auth_context.get('is_domain')
            #产生一个token，该方法传递的参数值分别为：user_id,password,None,None,None,None,auth_context非空，trust为空，include_catalog为true,token_audit_id为None
            (token_id, token_data) = self.token_provider_api.issue_token(
                auth_context['user_id'], method_names, expires_at, project_id,
                is_domain, domain_id, auth_context, trust, include_catalog,
                parent_audit_id=token_audit_id)

            # NOTE(wanghong): We consume a trust use only when we are using
            # trusts and have successfully issued a token.
            if trust:
                self.trust_api.consume_use(trust['id'])

            return render_token_data_response(token_id, token_data,
                                              created=True)
```

进入issue_token方法。

```
    def issue_token(self, user_id, method_names, expires_at=None,
                    project_id=None, domain_id=None, auth_context=None,
                    trust=None, include_catalog=True,
                    parent_audit_id=None):
       #判断bind是否设置，此处为否，跳过
        if auth_context and auth_context.get('bind'):
            # NOTE(lbragstad): Check if the token provider being used actually
            # supports bind authentication methods before proceeding.
            if not self._supports_bind_authentication:
                raise exception.NotImplemented(_(
                    'The configured token provider does not support bind '
                    'authentication.'))
        #判断是否为trust类型token,此处为否跳过
        if CONF.trust.enabled and trust:
            if user_id != trust['trustee_user_id']:
                raise exception.Forbidden(_('User is not a trustee.'))
        #判断是否为federation类型token，为否跳过
        token_ref = None
        if auth_context and self._is_mapped_token(auth_context):
            token_ref = self._handle_mapped_tokens(
                auth_context, project_id, domain_id)

        #method name为password
        access_token = None
        if 'oauth1' in method_names:
            access_token_id = auth_context['access_token_id']
            access_token = self.oauth_api.get_access_token(access_token_id)
       #获得token_data值
        token_data = self.v3_token_data_helper.get_token_data(
            user_id,
            method_names,
            domain_id=domain_id,
            project_id=project_id,
            expires=expires_at,
            trust=trust,
            bind=auth_context.get('bind') if auth_context else None,
            token=token_ref,
            include_catalog=include_catalog,
            access_token=access_token,
            audit_info=parent_audit_id)
        #将token_data中重点字段抽取并加工成为token_id,包括user_id, methods, project_id, domain_id, expires_at, audit_ids, trust_id, federated_info, access_token_id
        token_id = self._get_token_id(token_data)
        return token_id, token_data
```

执行get_token_data方法：
```

    def get_token_data(self, user_id, method_names, domain_id=None,
                       project_id=None, expires=None, trust=None, token=None,
                       include_catalog=True, bind=None, access_token=None,
                       issued_at=None, audit_info=None):
        token_data = {'methods': method_names}

        # We've probably already written these to the token
       #token 为None，跳出
        if token:
            for x in ('roles', 'user', 'catalog', 'project', 'domain'):
                if x in token:
                    token_data[x] = token[x]
        #bind为None，跳出
        if bind:
            token_data['bind'] = bind
        #设置scope data数据，由于传递的domain_id和project_id为None，因此token_data不变
        self._populate_scope(token_data, domain_id, project_id)
        #判断是否为admin project
        if token_data.get('project'):
            self._populate_is_admin_project(token_data)
        #添加user 信息至token_data
        self._populate_user(token_data, user_id, trust)
       #添加role信息至token_data,由于domain_id,project_id,trust为空，因此token_data中role字段为空
        self._populate_roles(token_data, user_id, domain_id, project_id, trust,
                             access_token)
        #注入audit信息
        self._populate_audit_info(token_data, audit_info)

        if include_catalog:
            #注入catalog信息，为空
            self._populate_service_catalog(token_data, user_id, domain_id,
                                           project_id, trust)
        #如果是federation 类型token，则会注入可访问服务信息
        self._populate_service_providers(token_data)
        self._populate_token_dates(token_data, expires=expires,
                                   issued_at=issued_at)
        #注入oauth字段，此处access_token为空，因此该字段值同为同
        self._populate_oauth_section(token_data, access_token)
        return {'token': token_data}
```

执行命令行openstack token issue时，该方法传入的参数request为：

`{'environ': {'routes.route': <routes.route.Route object at 0x7f6a92c87810>, 'webob._parsed_query_vars': (GET([]), ''), 'SERVER_SOFTWARE': 'gunicorn/19.7.1', 'SCRIPT_NAME': '/v3', 'webob.adhoc_attrs': {'response': <Response at 0x7f6a92991210 200 OK>}, 'REQUEST_METHOD': 'POST', 'keystone.oslo_request_context': <keystone.common.context.RequestContext object at 0x7f6a92959710>, 'PATH_INFO': '/auth/tokens', 'SERVER_PROTOCOL': 'HTTP/1.1', 'QUERY_STRING': '', 'CONTENT_LENGTH': '151', 'HTTP_USER_AGENT': 'osc-lib/1.7.0 keystoneauth1/3.1.0 python-requests/2.14.2 CPython/2.7.5', 'HTTP_CONNECTION': 'keep-alive', 'REMOTE_PORT': '54277', 'SERVER_NAME': '192.168.109.2', 'REMOTE_ADDR': '192.168.109.3', 'wsgi.url_scheme': 'http', 'wsgiorg.routing_args': (<routes.util.URLGenerator object at 0x7f6a92991050>, {}), 'webob._body_file': (<_io.BufferedReader>, <gunicorn.http.body.Body object at 0x7f6a92f7b690>), 'SERVER_PORT': '5000', 'wsgi.input': <_io.BytesIO object at 0x7f6a92b9be90>, 'HTTP_HOST': '192.168.109.2:5000', 'wsgi.multithread': True, 'openstack.params': {u'auth': {u'identity': {u'password': {u'user': {u'domain': {u'name': u'Default'}, u'password': u'Fhroot@123', u'name': u'test_3_11'}}, u'methods': [u'password']}}}, 'routes.url': <routes.util.URLGenerator object at 0x7f6a92991050>, 'HTTP_ACCEPT': 'application/json', 'openstack.request_id': 'req-ee582def-84f7-4c94-b343-0da4747dabfe', 'wsgi.version': (1, 0), 'openstack.context': {'token_id': None}, 'RAW_URI': '/v3/auth/tokens', 'wsgi.run_once': False, 'wsgi.errors': <gunicorn.http.wsgi.WSGIErrorsWrapper object at 0x7f6a92b70f90>, 'wsgi.multiprocess': True, 'keystone.token_auth': <keystonemiddleware.auth_token._user_plugin.UserAuthPlugin object at 0x7f6a92959290>, 'gunicorn.socket': <eventlet.greenio.base.GreenSocket object at 0x7f6a92f7b550>, 'webob.is_body_seekable': True, 'CONTENT_TYPE': 'application/json', 'wsgi.file_wrapper': <class 'gunicorn.http.wsgi.FileWrapper'>, 'HTTP_ACCEPT_ENCODING': 'gzip, deflate'}}`

auth参数为：

`{u'identity': {u'password': {u'user': {u'domain': {u'name': u'Default'}, u'password': u'Fhroot@123', u'name': u'test_3_11'}}, u'methods': [u'password']}}`

正常包含scope所传递的auth信息为：

`{u'scope': {u'project': {u'domain': {u'name': u'Default'}, u'name': u'admin'}}, u'identity': {u'password': {u'user': {u'domain': {u'name': u'Default'}, u'password': u'Fhroot@123', u'name': u'admin'}}, u'methods': [u'password']}}`



---

查看端口的进程状况：netstat -tunlp |grep {port_id}
查看端口的监听状况：lsof -i:{port_id}

---


### 电信云中keystone-api提供服务实现过程：

/usr/lib/systemd/system/openstack-keystone.service    --提供systemd管理keystone方式，指定service入口脚本为：/usr/bin/keystone-all start 

/usr/bin/keystone-all   脚本，用于接收命令行脚本，并执行与其具体服务相关的python脚本。执行：/usr/share/keystone' public:application --name keystone-public 连接keystone 服务。

接着执行：/usr/share/keystone/public.py 中application = wsgi_server.initialize_public_application()并传递参数--name keystone-public . 如此，非all-in-one环境会起12*1.5=18个名称为keystone-public进程，用于处理keystone-api请求，并占用5000端口。
云环境访问keystone端口为：  GET http://192.168.109.2:5000/v3  
  一般是admin监听35357端口，main监听5000端口，因此访问5000端口的请求都会相应转发至paste-api定义的         [composite:main].

---
概念：

+ gunicorn是一个python Wsgi http server
+  LDAP 和可插拔的身份验证模块