# CUDA 12.1 runtime + cuDNN8, matching the torch==2.5.1+cu121 wheels in requirements.txt
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# 系統套件 + 帳號。Python 由後面的 conda 提供，這裡不裝系統 Python。
# tini 給 ssh 開機用，git/build-essential 給少數要編譯的套件用。
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        bzip2 \
        ca-certificates \
        build-essential \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
        git \
        openssh-server \
        tini \
        tmux \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && groupadd ml \
    && for u in ivy stella jane aegon dennis belle; do \
           useradd -m -s /bin/bash -G ml "$u"; \
       done

# 每人各自帳號、各自金鑰登入，不共用 root。公鑰本身不是機密，烤進公開 image 沒關係——
# 只有對應私鑰的人才能登入。之後要加新人，往 pubkeys/ 加一個檔案、上面 for 迴圈加個名字就好。
COPY pubkeys/ /tmp/pubkeys/
RUN for u in ivy stella jane aegon dennis belle; do \
        mkdir -p /home/$u/.ssh \
        && cp /tmp/pubkeys/$u.pub /home/$u/.ssh/authorized_keys \
        && chmod 700 /home/$u/.ssh \
        && chmod 600 /home/$u/.ssh/authorized_keys \
        && chown -R $u:$u /home/$u/.ssh; \
    done \
    && rm -rf /tmp/pubkeys

# 每個人登入後自動跳到自己在 /share 底下的資料夾，不用自己 cd
# （/share 是 runtime 才掛進來的，容器裡沒有就算了）
RUN echo 'cd "/share/$(whoami)" 2>/dev/null || true' > /etc/profile.d/ml-cd.sh \
    && chmod +x /etc/profile.d/ml-cd.sh

# Miniforge：用 conda-forge channel，不是 Anaconda 的 defaults channel，避免商業使用的授權疑慮。
# 裝在 /opt/conda，env 裡的 Python 版本跟系統完全無關，之後要換版本只要改下面的 python=3.10。
ENV CONDA_DIR=/opt/conda
ENV PATH=$CONDA_DIR/bin:$PATH
RUN curl -fsSL https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -o /tmp/miniforge.sh \
    && bash /tmp/miniforge.sh -b -p $CONDA_DIR \
    && rm /tmp/miniforge.sh \
    && conda clean -afy

# 共用的基礎環境，所有人登入預設都在這裡，requirements.txt 裝的套件都在這。
# 個人如果有特殊套件需求，自己 clone 一份出去裝，不要直接動這個共用 env：
#   conda create --clone ml -n <你的名字>
# clone 是本地複製，base 已經裝好的套件不用重新下載/安裝，之後手動 conda activate <你的名字> 即可。
RUN conda create -y -n ml python=3.10 \
    && conda clean -afy

# 把預設 PATH 直接指到 ml env 的 bin，讓 `docker compose exec ml python ...`
# 這種不經過登入 shell（不會跑 /etc/profile.d）的用法，也直接拿到裝好 requirements 的 python，
# 不會落到什麼都沒裝的 conda base env。
ENV PATH=$CONDA_DIR/envs/ml/bin:$PATH

EXPOSE 22

WORKDIR /share

COPY requirements.txt .

# torch/torchvision/torchaudio use the +cu121 local version tag, only published on
# PyTorch's own wheel index, so it must be added as an extra index for pip.
RUN $CONDA_DIR/envs/ml/bin/pip install --upgrade pip \
    && $CONDA_DIR/envs/ml/bin/pip install -r requirements.txt --extra-index-url https://download.pytorch.org/whl/cu121

# ml 群組共用 /opt/conda：讓群組成員都能在裡面建自己的 env、裝套件。
# setgid 讓新建的檔案/資料夾自動繼承 ml 群組，不用每個人各自 chmod。
RUN chgrp -R ml $CONDA_DIR \
    && chmod -R g+rwX $CONDA_DIR \
    && find $CONDA_DIR -type d -exec chmod g+s {} \;

# 登入自動啟用共用 base env，不用自己 conda activate
RUN echo '. /opt/conda/etc/profile.d/conda.sh && conda activate ml' > /etc/profile.d/ml-conda.sh \
    && chmod +x /etc/profile.d/ml-conda.sh

# image 只包環境（conda + 套件 + sshd），不烤程式碼跟資料進去——
# 程式碼跟資料一律靠 docker-compose.yml 的 /share bind mount 在執行期即時提供。
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]

# Pure compute/script environment: keep the container alive so you can
# `docker compose exec ml python your_script.py` or open a shell into it.
# 強行讓 Container 保持開機狀態
CMD ["tail", "-f", "/dev/null"]
