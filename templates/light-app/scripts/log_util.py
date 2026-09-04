"""log_util.py — 脚本确定性日志（写入 logs/scripts/<name>.log）

用法:
  from log_util import get
  logger = get('db_query')
  logger.warning('...')   # 只进文件，不影响 stdout/JSON 契约

文件分配:
  db_query.log   网关 warning/error（异常信号轨）
  sql.log        网关成功 SQL 全量（执行语料轨，算法抽象用）
  build.log      构建结果
  validate.log   验证结果
  serve.log      服务事件

关联: 环境变量 EXEC_TASK 已设时，每条日志注入 `task=<EXEC_TASK>` 前缀，
用于把 SQL/事件归到触发它们的用户任务（SOP 指示 agent 网关调用前带 EXEC_TASK=<task> 前缀）。
兜底: 若 EXEC_TASK 未设，回退读取 `logs/agent/.active-task` 标记文件（agent 任务开始写入），
覆盖"agent 自写脚本内 subprocess 调用网关未传播环境变量"的场景（直接 bash 调用优先用 EXEC_TASK 内联）。
局限: `.active-task` 为**单会话兜底**——多会话并发（同宿主多 agent 同时作业）时会互相覆盖导致日志归错任务；
并发场景应优先经 subprocess 透传 EXEC_TASK（`os.environ['EXEC_TASK']=...` 或 `env={**os.environ, 'EXEC_TASK': task}`）。

格式: 时间 [级别] [脚本名] task=<任务> 消息
"""
import logging
import os

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_LOGS_DIR = os.path.join(_ROOT, 'logs', 'scripts')
_ACTIVE_TASK_PATH = os.path.join(_ROOT, 'logs', 'agent', '.active-task')
_FORMAT = '%(asctime)s [%(levelname)s] [%(name)s] %(message)s'

_registry = {}


class _TaskFormatter(logging.Formatter):
    """注入任务标识：优先 EXEC_TASK 环境变量，回退 .active-task 标记文件。"""

    def format(self, record):
        task = os.environ.get('EXEC_TASK') or self._read_active_task()
        prefix = f'task={task} ' if task else ''
        return prefix + super().format(record)

    @staticmethod
    def _read_active_task():
        try:
            with open(_ACTIVE_TASK_PATH, encoding='utf-8') as f:
                return f.read().strip() or None
        except OSError:
            return None


def get(name):
    if name in _registry:
        return _registry[name]
    os.makedirs(_LOGS_DIR, exist_ok=True)
    logger = logging.getLogger('exec.' + name)
    handler = logging.FileHandler(os.path.join(_LOGS_DIR, name + '.log'), encoding='utf-8')
    handler.setFormatter(_TaskFormatter(_FORMAT, datefmt='%Y-%m-%d %H:%M:%S'))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    _registry[name] = logger
    return logger
