## 制作可直接启动的windows镜像
  
  要创建一个预安装了指定Windows版本并可直接启动的镜像，请按照以下步骤操作：
  
  #### 1. 使用本项目代码制作基础镜像
  已变更了Dockerfile和disk.sh文件，变更如下：
  - 在Dockerfile中将storage目录修改为非挂载目录

  ```
  RUN mkdir -p /storage
  ```
  
  - 在disk.sh中增加overlay附加磁盘支持，避免将操作系统镜像打包进镜像后无写入权限的问题。容器启动时会基于系统盘增加附加磁盘，效果如下：
  ```
   [root@localhost win7]# docker exec -it win7 ls -l /storage
    total 12990680
    -rw-r--r-- 1 root root  2564816896 Oct 22 06:36 data-overlay.qcow2
    -rw-r--r-- 1 root root 10737418240 Oct 22 06:02 data.img
    -rw-r--r-- 1 root root          23 Oct 22 06:01 windows.base
    -rw-r--r-- 1 root root           0 Oct 22 06:02 windows.boot
    -rw-r--r-- 1 root root          18 Oct 22 06:02 windows.mac
    -rw-r--r-- 1 root root          15 Oct 22 06:01 windows.mode
    -rw-r--r-- 1 root root           5 Oct 22 06:01 windows.ver

  ```
  其中data-overlay.qcow2文件是启动时自动新建的，其他文件是对应版本windows系统安装后生成的。

  使用docker build命令构建基础镜像，例如：
  ```
  docker build -t win7-base .
  ```

  #### 2. 按照正常流程安装操作系统
  按照正常流程安装操作系统以便获取storage目录下的文件作为基础操作系统文件。
  
  例如，在windows7镜像中，执行以下命令可查看windows7系统安装后的文件，拷贝挂载目录下的文件到本地目录。
  ```
  docker exec -it win7 ls -l /storage
  ```
  #### 3. 基于基础操作系统文件制作可直接启动的镜像
  准备文件夹，将基础操作系统文件拷贝到该文件夹下，例如：
  ```
  mkdir -p win7/base
  cp -r /storage/* win7/base/
  ```
  win7下增加Dockerfile文件，内容如下：
  ```
    # 基础镜像
    FROM win7-base

    # 设置环境变量（可选，根据你的 Win7 配置,初始资源尽量小一些）
    ENV VERSION=7
    ENV RAM_SIZE=2G
    ENV CPU_CORES=2
    ENV DISK_SIZE=10G

    RUN chmod -R 777 /storage

    # 复制已有的 Win7 系统盘到镜像里
    COPY base/ /storage/

    # 暴露端口（可选，保持与原镜像一致）
    EXPOSE 8006 3389

    # 使用原始 entrypoint
    ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]

  ```

  执行docker build命令构建镜像，例如：
  ```
  docker build -t win7:base-20251022 .
  ```
#### 4. 启动镜像
  使用docker compose命令启动镜像，docker-compose.yml文件内容例如：
  ```
  services:
  windows:
    image: win7:base-20251022
    privileged: true
    container_name: win7
    environment:
      VERSION: "7"
      RAM_SIZE: "4G"
      CPU_CORES: "2"
      DISK_SIZE: "10G"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - 8006:8006
      - 3389:3389
    restart: always
    stop_grace_period: 2m

  ```

  启动镜像，例如：
  ```
  docker compose up -d
  ```

#### 5. 安装openssh-server
  (1) 安装openssh-server
  在windows系统中安装openssh-server，参考https://github.com/PowerShell/Win32-OpenSSH
  安装完成后：
  - 在服务列表中检查sshd服务是否正常运行
  - 配置系统环境变量
  - 在cmd中使用ssh命令测试是否正常
    例如：
    ```
    ssh -p 22 Docker@127.0.0.1
    ```
  - 直接关闭windows防火墙（不用重新打镜像），或者在define.sh中增加以下内容，允许ssh连接（需要重新安装windows才能生效）：
  ```
  echo "\"22:TCP\"=\"22:TCP:*:Enabled:SSH Service\""
  ```
  (2) commit镜像
  执行docker commit命令提交镜像，例如：
  ```
  docker commit win7 win7:base-20251022-ssh
  ```
  其中win7是容器名称，win7:base-20251022-ssh是新镜像名称。

  (3) 启动新镜像
  使用docker compose命令启动新镜像，docker-compose.yml文件内容例如：
  ```
  services:
  windows:
    image: win7:base-20251022-ssh
    privileged: true
    container_name: win7-ssh
    environment:
      VERSION: "7"
      RAM_SIZE: "4G"
      CPU_CORES: "2"
      DISK_SIZE: "10G"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - 8006:8006
      - 3389:3389
      - 22:22
    restart: always
    stop_grace_period: 2m

  ```