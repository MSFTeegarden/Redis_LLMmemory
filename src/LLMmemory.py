## Import Libraries
##//////////////////////////////##
import streamlit as st
import tiktoken
import os
from redisvl.extensions.session_manager import StandardSessionManager
from openai import AzureOpenAI
import redis

st.set_page_config(layout="wide")

## Pull in environemnt variables ##
## //////////////////////////// ##
@st.cache_data
def get_env():
    api_key = os.getenv("AZURE_OPENAI_API_KEY")
    azure_endpoint = os.getenv("AZURE_OPENAI_ENDPOINT")
    redis_endpoint = os.getenv("REDIS_ENDPOINT")
    redis_password = os.getenv("REDIS_PASSWORD")
    return api_key, azure_endpoint, redis_endpoint, redis_password

api_key, azure_endpoint, redis_endpoint, redis_password = get_env()

## Initializations
##////////////////////////////// ##

@st.cache_resource
def initAOAI():
    ## Initialize the Azure OpenAI API
    client = AzureOpenAI(
        api_version="2024-02-01",  
        api_key= api_key,
        azure_endpoint= azure_endpoint
    )
    return client

client = initAOAI()

# create a connection string for the Redis Vector Store. Uses Redis-py format: https://redis-py.readthedocs.io/en/stable/connections.html#redis.Redis.from_url
# This example assumes TLS is enabled. If not, use "redis://" instead of "rediss://
# Note: the endpoint must have the port included in the URL. For example, "mycache.eastus.redis.azure.net:10000"
redis_url = "rediss://:" + redis_password + "@"+ redis_endpoint

users = ["Satya", "Steve", "Bill"]

@st.cache_resource
def initSessionManager(redis_url):
    ## Initialize the Session Manager
    session_manager = StandardSessionManager(
        name='mysession',
        redis_url=redis_url
    )
    session_manager.clear() # clear anything out from previous runs
    for user in users:
        session_manager.add_message({"role": "system", "content": "You are a helpful assistant."}, session_tag=user)
    return session_manager

session_manager = initSessionManager(redis_url)

# Set up a Redis client to expire keys after a certain amount of time
redis_client = redis.Redis.from_url(redis_url)

## Variables
##//////////////////////////////##
systeminstructions = ["Standard ChatGPT", "Extremely Brief", "Obnoxious American"]

if "messages" not in st.session_state:
    st.session_state.messages = session_manager.get_recent(top_k=5, session_tag="Satya")[1:] # load the last five messages into the chat box

if "userselectbox" not in st.session_state:
    st.session_state.userselectbox = 'Satya' # set Satya as the default user

if "contextwindow" not in st.session_state:
    st.session_state.contextwindow = 5 # set the default context window

## Functions
##//////////////////////////////##
def calculate_tokens(text):
    encoding = tiktoken.get_encoding("cl100k_base")
    tokens_per_message = 3
    tokens_per_name = 1
    num_tokens = 0
    for message in text:
        num_tokens += tokens_per_message
        for key, value in message.items():
            num_tokens += len(encoding.encode(value))
            if key == "name":
                num_tokens += tokens_per_name
    num_tokens += 3  # every reply is primed with <|start|>assistant<|message|>
    return num_tokens

def add_ttl(ttl_length, contextwindow, user):
    messages=session_manager.get_recent(top_k=contextwindow,session_tag=user, raw=True)
    redis_keys = []
    for message in messages:
        id = message['id']
        redis_keys.append(id)
    for key in redis_keys:
        redis_client.expire(key, ttl_length)

def calculate_cost(num_input_tokens, num_output_tokens):
    input_cost_per_1M_tokens = 5.0
    output_cost_per_1M_tokens = 15.0
    input_cost = (num_input_tokens / 1000000) * input_cost_per_1M_tokens
    output_cost = (num_output_tokens / 1000000) * output_cost_per_1M_tokens
    total_cost = input_cost + output_cost
    return total_cost

def ask_openai_session(historylength, user):
    messages = session_manager.get_recent(top_k=historylength, session_tag=user)[1:] # get the last n messages, excluding the system message
    systemmessage = get_system_instructions(user)
    messages.insert(0, systemmessage) # insert the system message at the beginning of the list
    response = client.chat.completions.create(
        model="demo-gpt-4o", # model = "deployment_name"
        messages=messages,
        max_tokens=2000
    )
    session_manager.add_message({"role": "assistant", "content": response.choices[0].message.content}, session_tag=user)
    return response.choices[0].message.content

def clear_user_session(user):
    messages=session_manager.get_recent(top_k=100,session_tag=user, raw=True)
    for message in messages:
        id = message['entry_id']
        session_manager.drop(id)
    session_manager.add_message({"role": "system", "content": "You are a helpful assistant."}, session_tag=user)

def update_system_instructions(user, systeminstruction):
    messages=session_manager.get_recent(top_k=100,session_tag=user, raw=True)
    systemmessage = messages[0]
    keyname = systemmessage['id']
    if systeminstruction == "Standard ChatGPT":
        redis_client.hset(keyname, "content", "You are a helpful assistant.")
    if systeminstruction == "Extremely Brief":
        redis_client.hset(keyname, "content", "You are a VERY brief assistant. Keep your responses as short as possible.")
    elif systeminstruction == "Obnoxious American":
        redis_client.hset(keyname, "content", "You are a VERY pro-American assistant. Make sure to emphasize how great the good ole' USA is in your responses. It's okay to be obnoxious.")

def get_system_instructions(user):
    messages=session_manager.get_recent(top_k=100,session_tag=user)
    systemmessage = messages[0]
    return systemmessage
# This function is called when the user changes the user in the selectbox OR each time a prompt is submitted. It updates what chat history is shown.
def update_text_display(): 
    newuser = st.session_state.userselectbox
    usermessages = session_manager.get_recent(top_k=5, session_tag=newuser)
    usermessages = usermessages[1:] # remove the first message, which is the system message
    for message in usermessages:
        with main.chat_message(message["role"]):
            st.markdown(message["content"])

def clear_text_and_session():
    st.session_state["main_text"] = None
    st.session_state["messages"] = []
    session_manager.clear()
    main.empty()
    for user in users:
        session_manager.add_message({"role": "system", "content": "You are a helpful assistant."}, session_tag=user)
    main.write('Session cleared') 

## Start of the streamlit app
## ///////////////////////////##


main = st.container(height=480, key="main_text")
prompt = st.chat_input(placeholder="Ask a question", key="main_prompt")
user = st.sidebar.selectbox("Select User", ("Satya", "Steve", "Bill"), on_change=update_text_display(), key="userselectbox")
systeminstructions = st.sidebar.selectbox("System Instructions", systeminstructions, key="systeminstructions")

if systeminstructions:
    update_system_instructions(user, systeminstructions)

contextwindow = st.sidebar.slider("Length of chat history", 1, 20, key="contextwindow")
chathistory = session_manager.get_recent(top_k=contextwindow, as_text=False, session_tag=user)
tokens = st.sidebar.metric(label="Chat history tokens", value=calculate_tokens(chathistory))

ttl_length = st.sidebar.slider("TTL time (seconds)", 1, 600, 60)

ttl_submit = st.sidebar.button("Set TTL of chat history")
if ttl_submit:
    add_ttl(ttl_length, contextwindow, user)

with main:

    if prompt:
        main.chat_message("user").write(prompt)
        session_manager.add_message({"role": "user", "content": prompt}, session_tag=user)
        historylength = st.session_state.contextwindow
        reply = ask_openai_session(historylength, user)
        main.chat_message(f"AI").write(reply)

clearsession = st.sidebar.button('Clear user session data')
if clearsession:
    clear_user_session(user)
    main.empty()
    main.write('Session cleared')


st.sidebar.button('Clear ALL session data', on_click=clear_text_and_session)

# Update the token metric
chathistory = session_manager.get_recent(top_k=contextwindow, as_text=False, session_tag=user)
tokens.metric(label="Chat history tokens", value=calculate_tokens(chathistory))