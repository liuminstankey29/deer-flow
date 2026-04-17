from typing import override

from langchain.agents.middleware import SummarizationMiddleware as BaseSummarizationMiddleware
from langchain_core.messages.human import HumanMessage


class SummarizationMiddleware(BaseSummarizationMiddleware):
    @override
    def _build_new_messages(self, summary: str) -> list[HumanMessage]:
        """Override the base implementation to let the human message with the special name 'summary'.
        And this message will be ignored to display in the frontend, but still can be used as context for the model.
        """
        return [HumanMessage(content=f"Here is a summary of the conversation to date:\n\n{summary}", name="summary")]
