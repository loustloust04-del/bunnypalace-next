import Foundation

// mp-code：记忆花园随包的编程会话命令行（CLI 子命令 + `mp-code mcp` 的 stdio MCP server）。逻辑全在 CodingCLI（也编进 app，单测可测），
// 这里只做两件事：忽略 SIGPIPE（下游关管道由 write 的 EPIPE 收场，不被信号杀掉），然后交给入口
signal(SIGPIPE, SIG_IGN)
exit(CodingCLI.main())
