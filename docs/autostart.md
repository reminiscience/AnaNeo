# Setting up AnaNeo to start automatically

There are two ways to make AnaNeo automatically start at logon. However, be aware that with both ways it's still *impossible to run AnaNeo on the login screen* due to technical restrictions. This means you'll always have to enter your password using the native layout. If this is not acceptable, check if your preferred layout also provides a native driver DLL.

## Shortcut in startup directory

This method is easiest to setup but AnaNeo won't work in applications running with administrative privileges.

Right click `ananeo.exe` and select *Create shortcut*. Navigate to “C:\\Users\\[your user name]\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup” and copy the newly created shortcut into this directory.

## Using Task Scheduler

This method is a little more involved but it can run AnaNeo with administrative privileges, meaning it'll also work in elevated applications. First, make sure there is no AnaNeo shortcut in the startup directory.

Use the start menu search to open the “Task Scheduler”. Create a new task called “AnaNeo” with the following settings:

![Task Scheduler general tab](task_scheduler_general.png "Task Scheduler general tab")

Add a trigger for *At log on* and choose your user.

![Task Scheduler trigger tab](task_scheduler_triggers.png "Task Scheduler trigger tab")

As the action choose *Start a program* with the location of the AnaNeo executable.

![Task Scheduler actions tab](task_scheduler_actions.png "Task Scheduler actions tab")

If you're on a laptop it's important to disable the highlighted power saving setting.

![Task Scheduler conditions tab](task_scheduler_conditions.png "Task Scheduler conditions tab")

Finally, under *Settings* allow AnaNeo to run for longer than three days.

![Task Scheduler settings tab](task_scheduler_settings.png "Task Scheduler settings tab")