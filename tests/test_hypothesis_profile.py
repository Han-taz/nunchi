import os

from hypothesis import settings


def test_profiles_have_the_documented_example_counts() -> None:
    assert settings.get_profile("default").max_examples == 100
    assert settings.get_profile("nightly").max_examples == 3000


def test_the_loaded_profile_is_the_one_the_environment_names() -> None:
    wanted = os.environ.get("NUNCHI_HYPOTHESIS_PROFILE", "default")
    assert settings().max_examples == settings.get_profile(wanted).max_examples
