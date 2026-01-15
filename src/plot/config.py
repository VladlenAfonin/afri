import os
import dotenv


config = {
    **dotenv.dotenv_values(".env"),
    **os.environ,
}
