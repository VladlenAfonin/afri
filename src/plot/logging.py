import timeit

from plot.config import config


default_config = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "simple": {"format": "%(levelname)s:%(name)s:%(funcName)s():%(message)s"}
    },
    "handlers": {
        "stdout": {
            "class": "logging.StreamHandler",
            "formatter": "simple",
            "stream": "ext://sys.stdout",
        },
    },
    "loggers": {
        "plot": {
            "level": f"{config.get('LOGLEVEL', 'INFO').upper()}",
            "handlers": ["stdout"],
        },
    },
}


def logging_mark(logger):
    def wrapper1(function):
        def wrapper(*args, **kwargs):
            logger.debug("begin function %s", function.__name__)
            debug_begin = timeit.default_timer()

            result = function(*args, **kwargs)

            debug_end = timeit.default_timer()
            logger.debug(
                "end function %s. result = %s. elapsed = %d ms",
                function.__name__,
                result,
                debug_end - debug_begin,
            )

            return result

        return wrapper

    return wrapper1
